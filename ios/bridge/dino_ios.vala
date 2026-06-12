// iOS bridge for Dino: boots the full libdino service stack (database,
// stream interactor, all managers) without any GTK dependency and exposes a
// small C API for the SwiftUI shell.
//
// Threading model: a dedicated thread runs the GLib main loop. Every API
// call marshals onto that loop via Idle.add; results and spontaneous events
// flow back to Swift as JSON lines through a single callback (invoked on the
// GLib thread — the Swift side hops to the main queue).

using Dino.Entities;

namespace DinoIos {

public delegate void EventCb(string json);

public class Application : GLib.Application, Dino.Application {
    public Dino.Database db { get; set; }
    public Dino.Entities.Settings settings { get; set; }
    public Dino.StreamInteractor stream_interactor { get; set; }
    public Dino.Plugins.Registry plugin_registry { get; set; default = new Dino.Plugins.Registry(); }
    public Dino.SearchPathGenerator? search_path_generator { get; set; }

    public Application() throws Error {
        Object(application_id: "im.dino.ios", flags: ApplicationFlags.NON_UNIQUE);
        init();
    }

    public void handle_uri(string jid, string query, Gee.Map<string, string> options) { }
}

private static Application? app = null;
private static EventCb? event_cb = null;

private static void emit(string json) {
    if (event_cb != null) event_cb(json);
}

private static string enc_name(Encryption e) {
    switch (e) {
        case Encryption.OMEMO: return "OMEMO";
        case Encryption.PGP: return "PGP";
        case Encryption.NONE: return "NONE";
        default: return "UNKNOWN";
    }
}

private static string state_name(Dino.ConnectionManager.ConnectionState state) {
    switch (state) {
        case Dino.ConnectionManager.ConnectionState.CONNECTED: return "CONNECTED";
        case Dino.ConnectionManager.ConnectionState.CONNECTING: return "CONNECTING";
        default: return "DISCONNECTED";
    }
}

private static string esc(string? s) {
    if (s == null) return "";
    StringBuilder b = new StringBuilder();
    for (int i = 0; i < s.length; i++) {
        uint8 c = (uint8) s[i];
        switch (c) {
            case '"': b.append("\\\""); break;
            case '\\': b.append("\\\\"); break;
            case '\n': b.append("\\n"); break;
            case '\r': b.append("\\r"); break;
            case '\t': b.append("\\t"); break;
            default:
                if (c < 0x20) b.append_printf("\\u%04x", c);
                else b.append_c((char) c);
                break;
        }
    }
    return b.str;
}

public void start(owned EventCb cb) {
    event_cb = (owned) cb;
    new Thread<bool>("dino-main", () => {
        try {
            app = new Application();
        } catch (Error e) {
            emit(@"{\"type\":\"fatal\",\"message\":\"$(esc(e.message))\"}");
            return false;
        }

#if WITH_OMEMO
        var omemo_plugin = new Dino.Plugins.Omemo.Plugin();
        omemo_plugin.registered(app);
#endif
#if WITH_HTTP_FILES
        var http_files_plugin = new Dino.Plugins.HttpFiles.Plugin();
        http_files_plugin.registered(app);
#endif

        var si = app.stream_interactor;
        string? log_xmpp = Environment.get_variable("DINO_LOG_XMPP");
        if (log_xmpp != null) si.connection_manager.log_options = log_xmpp;
        si.connection_manager.connection_state_changed.connect((account, state) => {
            emit(@"{\"type\":\"connection\",\"account\":\"$(esc(account.bare_jid.to_string()))\",\"state\":\"$(state_name(state))\"}");
        });
        si.connection_manager.connection_error.connect((account, error) => {
            emit(@"{\"type\":\"connection_error\",\"account\":\"$(esc(account.bare_jid.to_string()))\",\"source\":\"$(error.source)\"}");
        });
        si.get_module(Dino.ContentItemStore.IDENTITY).new_item.connect((item, conversation) => {
            emit(content_item_json("message", item, conversation));
            push_conversations();
        });
        si.get_module(Dino.CounterpartInteractionManager.IDENTITY).received_state.connect((conversation, state) => {
            emit(@"{\"type\":\"chat_state\",\"conversation\":$(conversation.id),\"state\":\"$(esc(state))\"}");
        });
        si.get_module(Dino.AvatarManager.IDENTITY).received_avatar.connect((jid, account) => {
            push_avatar(account, jid);
        });
        si.get_module(Dino.ConversationManager.IDENTITY).conversation_activated.connect((conversation) => {
            push_conversations();
        });
        si.get_module(Dino.RosterManager.IDENTITY).updated_roster_item.connect(() => push_roster());
        si.get_module(Dino.RosterManager.IDENTITY).removed_roster_item.connect(() => push_roster());
        si.get_module(Dino.PresenceManager.IDENTITY).show_received.connect(() => push_roster());
        si.get_module(Dino.PresenceManager.IDENTITY).received_offline_presence.connect(() => push_roster());
        si.get_module(Dino.PresenceManager.IDENTITY).received_subscription_request.connect((jid, account) => {
            emit(@"{\"type\":\"subscription_request\",\"account\":\"$(esc(account.bare_jid.to_string()))\",\"jid\":\"$(esc(jid.bare_jid.to_string()))\"}");
        });

        emit("{\"type\":\"ready\"}");

        app.hold();
        app.run();
        return true;
    });
}

private static string content_item_json(string type, Dino.ContentItem item, Conversation conversation) {
    var mi = item as Dino.MessageItem;
    if (mi != null) {
        Message m = mi.message;
        string direction = m.direction == Message.DIRECTION_SENT ? "out" : "in";
        return "{\"type\":\"%s\",\"conversation\":%d,\"item\":%d,\"direction\":\"%s\",\"from\":\"%s\",\"body\":\"%s\",\"time\":%lld,\"encryption\":\"%s\"}".printf(
            type, conversation.id, item.id, direction, esc(m.from.to_string()), esc(m.body), m.time.to_unix(), enc_name(m.encryption));
    }
    return "{\"type\":\"%s\",\"conversation\":%d,\"item\":%d,\"kind\":\"%s\",\"time\":%lld}".printf(
        type, conversation.id, item.id, esc(item.type_), item.time.to_unix());
}

private static string conversation_json(Conversation c) {
    string name = Dino.get_conversation_display_name(app.stream_interactor, c, null);
    int unread = app.stream_interactor.get_module(Dino.ChatInteraction.IDENTITY).get_num_unread(c);
    string preview = "";
    string preview_direction = "";
    var latest = app.stream_interactor.get_module(Dino.ContentItemStore.IDENTITY).get_n_latest(c, 1);
    foreach (Dino.ContentItem item in latest) {
        var mi = item as Dino.MessageItem;
        if (mi != null) {
            preview = mi.message.body ?? "";
            preview_direction = mi.message.direction == Message.DIRECTION_SENT ? "out" : "in";
        } else {
            preview = "[file]";
        }
    }
    long last_time = c.last_active != null ? (long) c.last_active.to_unix() : 0;
    string kind = c.type_ == Conversation.Type.GROUPCHAT ? "groupchat" : "chat";
    return "{\"id\":%d,\"account\":\"%s\",\"jid\":\"%s\",\"name\":\"%s\",\"encryption\":\"%s\",\"kind\":\"%s\",\"unread\":%d,\"preview\":\"%s\",\"preview_direction\":\"%s\",\"time\":%ld}".printf(
        c.id, esc(c.account.bare_jid.to_string()), esc(c.counterpart.to_string()), esc(name), enc_name(c.encryption),
        kind, unread, esc(preview), preview_direction, last_time);
}

private static void push_avatar(Account account, Xmpp.Jid jid) {
    File? file = app.stream_interactor.get_module(Dino.AvatarManager.IDENTITY).get_avatar_file(account, jid);
    if (file != null && file.get_path() != null) {
        emit(@"{\"type\":\"avatar\",\"jid\":\"$(esc(jid.bare_jid.to_string()))\",\"path\":\"$(esc(file.get_path()))\"}");
    }
}

private static void push_conversations() {
    var convs = app.stream_interactor.get_module(Dino.ConversationManager.IDENTITY).get_active_conversations();
    var b = new StringBuilder("{\"type\":\"conversations\",\"list\":[");
    bool first = true;
    foreach (Conversation c in convs) {
        if (!first) b.append_c(',');
        first = false;
        b.append(conversation_json(c));
    }
    b.append("]}");
    emit(b.str);
}

private static Account? first_enabled_account() {
    foreach (Account a in app.db.get_accounts()) {
        if (a.enabled) return a;
    }
    return null;
}

private static Conversation? conversation_by_id(int id) {
    foreach (Conversation c in app.stream_interactor.get_module(Dino.ConversationManager.IDENTITY).get_active_conversations()) {
        if (c.id == id) return c;
    }
    return null;
}

public void add_account(string jid_str, string password) {
    string j = jid_str; string p = password;
    Idle.add(() => {
        try {
            var jid = new Xmpp.Jid(j);
            // Re-enabling an existing (signed-out) account keeps its id and
            // therefore its conversations and OMEMO device identity.
            foreach (Account existing in app.db.get_accounts()) {
                if (existing.bare_jid.equals_bare(jid)) {
                    existing.password = p;
                    if (!existing.enabled) {
                        existing.enabled = true;
                        app.stream_interactor.connect_account(existing);
                    }
                    emit(@"{\"type\":\"account_added\",\"account\":\"$(esc(existing.bare_jid.to_string()))\"}");
                    return Source.REMOVE;
                }
            }
            var account = new Account(jid, p);
            account.persist(app.db);
            account.enabled = true;
            app.stream_interactor.connect_account(account);
            emit(@"{\"type\":\"account_added\",\"account\":\"$(esc(account.bare_jid.to_string()))\"}");
        } catch (Error e) {
            emit(@"{\"type\":\"error\",\"message\":\"$(esc(e.message))\"}");
        }
        return Source.REMOVE;
    });
}

private static void push_roster() {
    var b = new StringBuilder("{\"type\":\"roster\",\"list\":[");
    bool first = true;
    foreach (Account a in app.db.get_accounts()) {
        if (!a.enabled) continue;
        var presence = app.stream_interactor.get_module(Dino.PresenceManager.IDENTITY);
        foreach (Xmpp.Roster.Item item in app.stream_interactor.get_module(Dino.RosterManager.IDENTITY).get_roster(a)) {
            if (item.jid == null) continue;
            if (!first) b.append_c(',');
            first = false;
            string? show = presence.get_last_show(item.jid, a);
            b.append("{\"account\":\"%s\",\"jid\":\"%s\",\"name\":\"%s\",\"subscription\":\"%s\",\"show\":\"%s\"}".printf(
                esc(a.bare_jid.to_string()), esc(item.jid.to_string()), esc(item.name ?? ""),
                esc(item.subscription ?? ""), esc(show ?? "offline")));
        }
    }
    b.append("]}");
    emit(b.str);
}

public void request_roster() {
    Idle.add(() => {
        push_roster();
        return Source.REMOVE;
    });
}

public void add_contact(string jid_str, string? alias) {
    string j = jid_str;
    string? a = alias == null || alias == "" ? null : alias;
    Idle.add(() => {
        try {
            var account = first_enabled_account();
            if (account == null) return Source.REMOVE;
            var jid = new Xmpp.Jid(j).bare_jid;
            app.stream_interactor.get_module(Dino.RosterManager.IDENTITY).add_jid(account, jid, a);
            app.stream_interactor.get_module(Dino.PresenceManager.IDENTITY).request_subscription(account, jid);
        } catch (Error e) {
            emit(@"{\"type\":\"error\",\"message\":\"$(esc(e.message))\"}");
        }
        return Source.REMOVE;
    });
}

public void remove_contact(string jid_str) {
    string j = jid_str;
    Idle.add(() => {
        try {
            var account = first_enabled_account();
            if (account == null) return Source.REMOVE;
            app.stream_interactor.get_module(Dino.RosterManager.IDENTITY).remove_jid(account, new Xmpp.Jid(j).bare_jid);
        } catch (Error e) {
            emit(@"{\"type\":\"error\",\"message\":\"$(esc(e.message))\"}");
        }
        return Source.REMOVE;
    });
}

public void respond_subscription(string jid_str, bool approve) {
    string j = jid_str;
    bool ok = approve;
    Idle.add(() => {
        try {
            var account = first_enabled_account();
            if (account == null) return Source.REMOVE;
            var jid = new Xmpp.Jid(j).bare_jid;
            var presence = app.stream_interactor.get_module(Dino.PresenceManager.IDENTITY);
            if (ok) {
                presence.approve_subscription(account, jid);
                presence.request_subscription(account, jid);
            } else {
                presence.deny_subscription(account, jid);
            }
        } catch (Error e) {
            emit(@"{\"type\":\"error\",\"message\":\"$(esc(e.message))\"}");
        }
        return Source.REMOVE;
    });
}

// Disables the account and disconnects, but keeps it in the database so a
// later sign-in reuses the same account id (conversations and the OMEMO
// device identity survive). Deleting accounts would re-key OMEMO each time.
public void sign_out() {
    Idle.add(() => {
        bool any = false;
        foreach (Account a in app.db.get_accounts()) {
            if (!a.enabled) continue;
            any = true;
            a.enabled = false;
            app.stream_interactor.disconnect_account.begin(a, (_, res) => {
                app.stream_interactor.disconnect_account.end(res);
                emit("{\"type\":\"signed_out\"}");
            });
        }
        if (!any) emit("{\"type\":\"signed_out\"}");
        return Source.REMOVE;
    });
}

public void request_state() {
    Idle.add(() => {
        var b = new StringBuilder("{\"type\":\"accounts\",\"list\":[");
        bool first = true;
        foreach (Account a in app.db.get_accounts()) {
            if (!a.enabled) continue;
            if (!first) b.append_c(',');
            first = false;
            b.append("{\"jid\":\"%s\",\"enabled\":%s,\"state\":\"%s\"}".printf(
                esc(a.bare_jid.to_string()), a.enabled ? "true" : "false",
                state_name(app.stream_interactor.connection_manager.get_state(a))));
        }
        b.append("]}");
        emit(b.str);
        push_conversations();
        push_roster();
        return Source.REMOVE;
    });
}

public void start_conversation(string jid_str) {
    string j = jid_str;
    Idle.add(() => {
        try {
            var account = first_enabled_account();
            if (account == null) {
                emit("{\"type\":\"error\",\"message\":\"No account configured\"}");
                return Source.REMOVE;
            }
            var cm = app.stream_interactor.get_module(Dino.ConversationManager.IDENTITY);
            Conversation conversation = cm.create_conversation(new Xmpp.Jid(j).bare_jid, account, Conversation.Type.CHAT);
            cm.start_conversation(conversation);
            push_conversations();
        } catch (Error e) {
            emit(@"{\"type\":\"error\",\"message\":\"$(esc(e.message))\"}");
        }
        return Source.REMOVE;
    });
}

public void request_messages(int conversation_id, int count) {
    int cid = conversation_id; int n = count;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c == null) return Source.REMOVE;
        var items = app.stream_interactor.get_module(Dino.ContentItemStore.IDENTITY).get_n_latest(c, n);
        var b = new StringBuilder();
        b.append_printf("{\"type\":\"history\",\"conversation\":%d,\"items\":[", cid);
        bool first = true;
        foreach (Dino.ContentItem item in items) {
            if (!first) b.append_c(',');
            first = false;
            b.append(content_item_json("item", item, c));
        }
        b.append("]}");
        emit(b.str);
        return Source.REMOVE;
    });
}

public void send_text(int conversation_id, string body) {
    int cid = conversation_id; string text = body;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c == null) {
            emit("{\"type\":\"error\",\"message\":\"Unknown conversation\"}");
            return Source.REMOVE;
        }
        Dino.send_message(c, text, 0, null, new Gee.ArrayList<Xmpp.Xep.MessageMarkup.Span>());
        return Source.REMOVE;
    });
}

// Marks the conversation as the focused one: read markers are sent and the
// unread count resets, mirroring desktop window-focus semantics.
public void focus_conversation(int conversation_id) {
    int cid = conversation_id;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c == null) return Source.REMOVE;
        var chat = app.stream_interactor.get_module(Dino.ChatInteraction.IDENTITY);
        chat.on_conversation_selected(c);
        chat.on_window_focus_in(c);
        push_conversations();
        return Source.REMOVE;
    });
}

public void blur_conversation(int conversation_id) {
    int cid = conversation_id;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c == null) return Source.REMOVE;
        app.stream_interactor.get_module(Dino.ChatInteraction.IDENTITY).on_window_focus_out(c);
        return Source.REMOVE;
    });
}

public void set_typing(int conversation_id, bool typing) {
    int cid = conversation_id;
    bool t = typing;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c == null) return Source.REMOVE;
        var chat = app.stream_interactor.get_module(Dino.ChatInteraction.IDENTITY);
        if (t) chat.on_message_entered(c);
        else chat.on_message_cleared(c);
        return Source.REMOVE;
    });
}

public void request_avatar(string jid_str) {
    string j = jid_str;
    Idle.add(() => {
        try {
            var account = first_enabled_account();
            if (account == null) return Source.REMOVE;
            push_avatar(account, new Xmpp.Jid(j).bare_jid);
        } catch (Error e) { }
        return Source.REMOVE;
    });
}

public void set_encryption(int conversation_id, bool omemo) {
    int cid = conversation_id; bool enc = omemo;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c != null) {
            c.encryption = enc ? Encryption.OMEMO : Encryption.NONE;
            push_conversations();
        }
        return Source.REMOVE;
    });
}

[CCode (cname = "dino_poc_register_tls_backend")]
extern void register_tls_backend();

public void init_glib_tls() {
    register_tls_backend();
}

}
