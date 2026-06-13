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
        message("gecko: gapplication constructed; storage=%s home=%s", Dino.Application.get_storage_dir(), Environment.get_home_dir());
        init();
        message("gecko: dino init complete");
    }

    public void handle_uri(string jid, string query, Gee.Map<string, string> options) { }
}

private static Application? app = null;
private static EventCb? event_cb = null;
private static string? push_proxy_jid = null;
private static string? push_token = null;
#if WITH_OMEMO
private static Dino.Plugins.Omemo.Plugin? omemo_plugin = null;
#endif

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

private static string notify_name(Conversation.NotifySetting s) {
    switch (s) {
        case Conversation.NotifySetting.ON: return "on";
        case Conversation.NotifySetting.OFF: return "off";
        case Conversation.NotifySetting.HIGHLIGHT: return "highlight";
        default: return "default";
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

// Boots the libdino service stack shared by the app and the Notification
// Service Extension: database, stream interactor, OMEMO + HTTP-file plugins,
// and the push module. Enabled accounts connect (and MAM-sync) automatically
// once the stack is built.
private static void boot_core() throws Error {
    app = new Application();
    // identify as Gecko (mobile client) to servers and other clients
    Dino.ModuleManager.client_identity_name = "Gecko";
    Dino.ModuleManager.client_identity_type = "phone";
    Account.resource_prefix = "gecko";
    // migrate pre-rename resources before restore() loads the accounts
    foreach (Qlite.Row row in app.db.account.select()) {
        string? res = row[app.db.account.resourcepart];
        if (res != null && res.has_prefix("dino.")) {
            app.db.account.update()
                .with(app.db.account.id, "=", row[app.db.account.id])
                .set(app.db.account.resourcepart, "gecko." + res.substring(5))
                .perform();
        }
    }
#if WITH_OMEMO
    omemo_plugin = new Dino.Plugins.Omemo.Plugin();
    omemo_plugin.registered(app);
#endif
#if WITH_HTTP_FILES
    var http_files_plugin = new Dino.Plugins.HttpFiles.Plugin();
    http_files_plugin.registered(app);
#endif
    app.stream_interactor.module_manager.initialize_account_modules.connect((account, list) => {
        list.add(new Xmpp.Xep.PushNotifications.Module());
        if (nse_mode) {
            // The extension must never advertise an "available" presence:
            // doing so makes the server flush its offline-message queue to
            // this throwaway session and re-trigger pushes when it drops (a
            // notification loop). MAM catch-up still runs (it keys off stream
            // negotiation, not presence), so the extension can read the
            // triggering message without these side effects.
            foreach (Xmpp.XmppStreamModule m in list) {
                var pm = m as Xmpp.Presence.Module;
                if (pm != null) pm.available_resource = false;
            }
        }
    });
}

// --- Notification Service Extension fetch path ---------------------------
// The NSE boots the stack, lets the enabled account connect and MAM-sync,
// and collects the incoming messages that arrive within its time budget,
// then returns a single {"type":"nse_result","messages":[...]} line. Each
// message carries everything the extension needs to decide on-device:
// conversation, sender, decrypted body, the conversation's effective notify
// setting, and whether it mentions the user.

private static bool nse_mode = false;
private static StringBuilder? nse_msgs = null;
private static bool nse_done = false;
private static bool nse_first = true;
private static uint nse_settle = 0;
private static Gee.HashSet<string>? nse_seen = null;

private static string nse_message_json(Dino.MessageItem mi, Conversation c) {
    Message m = mi.message;
    string from_display = Dino.get_participant_display_name(app.stream_interactor, c, m.from);
    string conv_name = Dino.get_conversation_display_name(app.stream_interactor, c, null);
    var effective = c.get_notification_setting(app.stream_interactor);
    bool is_group = c.type_ == Conversation.Type.GROUPCHAT;
    string body = display_body(m);
    bool mentioned = false;
    if (is_group) {
        string? nick = c.nickname ?? c.account.localpart;
        if (nick != null && nick != "") mentioned = body.down().contains(nick.down());
    }
    return "{\"conversation\":%d,\"conversation_name\":\"%s\",\"from\":\"%s\",\"body\":\"%s\",\"encrypted\":%s,\"notify\":\"%s\",\"groupchat\":%s,\"mentioned\":%s,\"time\":%lld}".printf(
        c.id, esc(conv_name), esc(from_display), esc(body),
        m.encryption != Encryption.NONE ? "true" : "false",
        notify_name(effective), is_group ? "true" : "false",
        mentioned ? "true" : "false", m.time.to_unix());
}

private static void nse_finish() {
    if (nse_done) return;
    nse_done = true;
    if (nse_settle != 0) { Source.remove(nse_settle); nse_settle = 0; }
    nse_msgs.append_c(']');
    emit(@"{\"type\":\"nse_result\",\"messages\":$(nse_msgs.str)}");
    if (app != null) app.quit();
}

public void nse_fetch(int timeout_ms, owned EventCb cb) {
    event_cb = (owned) cb;
    int hard_ms = timeout_ms;
    new Thread<bool>("dino-nse", () => {
        nse_mode = true;
        nse_msgs = new StringBuilder("[");
        nse_done = false;
        nse_first = true;
        nse_settle = 0;
        nse_seen = new Gee.HashSet<string>();
        try {
            boot_core();
        } catch (Error e) {
            emit(@"{\"type\":\"nse_result\",\"error\":\"$(esc(e.message))\",\"messages\":[]}");
            return false;
        }
        emit("{\"type\":\"nse_diag\",\"stage\":\"booted\"}");
        app.stream_interactor.connection_manager.connection_state_changed.connect((account, state) => {
            emit(@"{\"type\":\"nse_diag\",\"stage\":\"conn\",\"state\":\"$(state_name(state))\"}");
        });
        app.stream_interactor.connection_manager.connection_error.connect((account, error) => {
            emit(@"{\"type\":\"nse_diag\",\"stage\":\"conn_error\",\"source\":\"$(error.source)\"}");
        });
        app.stream_interactor.get_module(Dino.ContentItemStore.IDENTITY).new_item.connect((item, conversation) => {
            var mi = item as Dino.MessageItem;
            if (mi == null) return;
            Message m = mi.message;
            if (m.direction != Message.DIRECTION_RECEIVED) return;
            string body = display_body(m);
            if (body.strip() == "") return;
            // The same message can surface twice (offline delivery + MAM, or
            // duplicate publishes), so dedupe on sender + time + body.
            string key = "%s|%lld|%s".printf(m.from.to_string(), m.time.to_unix(), body);
            if (nse_seen.contains(key)) return;
            nse_seen.add(key);
            if (!nse_first) nse_msgs.append_c(',');
            nse_first = false;
            nse_msgs.append(nse_message_json(mi, conversation));
            // return shortly after the burst of MAM-synced messages settles
            if (nse_settle != 0) Source.remove(nse_settle);
            nse_settle = Timeout.add(2500, () => { nse_settle = 0; nse_finish(); return Source.REMOVE; });
        });
        // Connect enabled accounts explicitly: the app relies on the
        // GApplication `startup` signal (-> restore) to do this, but that path
        // doesn't drive the connection inside the extension, so trigger it
        // ourselves once the loop is running.
        Idle.add(() => {
            int n = 0;
            foreach (Account account in app.db.get_accounts()) {
                if (account.enabled) {
                    // Bind a distinct resource so the extension's connection
                    // never collides with the app's session (which would kick
                    // one off with a stream conflict).
                    account.set_ephemeral_resource("gecko-nse.%x".printf(Random.next_int()));
                    app.stream_interactor.connect_account(account);
                    n++;
                }
            }
            emit(@"{\"type\":\"nse_diag\",\"stage\":\"connect\",\"accounts\":$(n)}");
            return Source.REMOVE;
        });
        Timeout.add(hard_ms, () => { nse_finish(); return Source.REMOVE; });
        app.hold();
        app.run();
        return true;
    });
}

public void start(owned EventCb cb) {
    event_cb = (owned) cb;
    new Thread<bool>("dino-main", () => {
        message("gecko: creating application");
        try {
            boot_core();
        } catch (Error e) {
            emit(@"{\"type\":\"fatal\",\"message\":\"$(esc(e.message))\"}");
            return false;
        }
        message("gecko: application created");

        var si = app.stream_interactor;
        string? log_xmpp = Environment.get_variable("DINO_LOG_XMPP");
        if (log_xmpp != null) si.connection_manager.log_options = log_xmpp;
        si.connection_manager.connection_state_changed.connect((account, state) => {
            if (state == Dino.ConnectionManager.ConnectionState.CONNECTED) enable_mam_archiving(account);
            emit(@"{\"type\":\"connection\",\"account\":\"$(esc(account.bare_jid.to_string()))\",\"state\":\"$(state_name(state))\"}");
        });
        si.connection_manager.connection_error.connect((account, error) => {
            emit(@"{\"type\":\"connection_error\",\"account\":\"$(esc(account.bare_jid.to_string()))\",\"source\":\"$(error.source)\"}");
        });
        si.get_module(Dino.ContentItemStore.IDENTITY).new_item.connect((item, conversation) => {
            emit(content_item_json("message", item, conversation));
            var fi = item as Dino.FileItem;
            if (fi != null) {
                fi.file_transfer.notify["state"].connect(() => {
                    emit(content_item_json("message", fi, conversation));
                });
            }
            var mi = item as Dino.MessageItem;
            if (mi != null) {
                mi.message.notify["marked"].connect(() => {
                    emit(content_item_json("message", mi, conversation));
                });
            }
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
        si.get_module(Dino.MessageCorrection.IDENTITY).received_correction.connect((item) => {
            re_emit_item(item.id);
        });
        si.get_module(Dino.Reactions.IDENTITY).reaction_added.connect((account, item_id, jid, reaction) => {
            re_emit_item_delayed(item_id);
        });
        si.get_module(Dino.Reactions.IDENTITY).reaction_removed.connect((account, item_id, jid, reaction) => {
            re_emit_item_delayed(item_id);
        });
        si.get_module(Dino.RosterManager.IDENTITY).updated_roster_item.connect(() => push_roster());
        si.get_module(Dino.RosterManager.IDENTITY).removed_roster_item.connect(() => push_roster());
        si.get_module(Dino.PresenceManager.IDENTITY).show_received.connect(() => push_roster());
        si.get_module(Dino.PresenceManager.IDENTITY).received_offline_presence.connect(() => push_roster());
        si.get_module(Dino.PresenceManager.IDENTITY).received_subscription_request.connect((jid, account) => {
            emit(@"{\"type\":\"subscription_request\",\"account\":\"$(esc(account.bare_jid.to_string()))\",\"jid\":\"$(esc(jid.bare_jid.to_string()))\"}");
        });

        message("gecko: ready");
        emit("{\"type\":\"ready\"}");

        app.hold();
        app.run();
        return true;
    });
}

private static string file_state_name(FileTransfer.State s) {
    switch (s) {
        case FileTransfer.State.COMPLETE: return "complete";
        case FileTransfer.State.IN_PROGRESS: return "in_progress";
        case FileTransfer.State.FAILED: return "failed";
        default: return "not_started";
    }
}

private static string reactions_json(Dino.ContentItem item, Conversation conversation) {
    var b = new StringBuilder("[");
    var reactions = app.stream_interactor.get_module(Dino.Reactions.IDENTITY).get_item_reactions(conversation, item);
    bool first = true;
    foreach (var ru in reactions) {
        if (ru.jids.size == 0) continue;
        if (!first) b.append_c(',');
        first = false;
        bool me = false;
        foreach (Xmpp.Jid jid in ru.jids) {
            if (jid.equals_bare(conversation.account.bare_jid)) { me = true; break; }
        }
        b.append("{\"emoji\":\"%s\",\"count\":%d,\"me\":%s}".printf(esc(ru.reaction), ru.jids.size, me ? "true" : "false"));
    }
    b.append_c(']');
    return b.str;
}

private static string marked_name(Message.Marked m) {
    switch (m) {
        case Message.Marked.READ: return "read";
        case Message.Marked.RECEIVED: return "received";
        case Message.Marked.ACKNOWLEDGED: return "acknowledged";
        case Message.Marked.SENT: return "sent";
        case Message.Marked.SENDING: return "sending";
        case Message.Marked.UNSENT: return "unsent";
        case Message.Marked.WONTSEND: return "wontsend";
        case Message.Marked.ERROR: return "error";
        default: return "none";
    }
}

// Removes fallback (quoted-reply) character ranges from a message body for
// display, mirroring the desktop UI behaviour.
private static string display_body(Message m) {
    string body = m.body ?? "";
    if (m.quoted_item_id <= 0) return body;
    var fallbacks = m.get_fallbacks();
    if (fallbacks == null) return body;
    foreach (var fallback in fallbacks) {
        if (fallback.ns_uri != Xmpp.Xep.Replies.NS_URI) continue;
        foreach (var loc in fallback.locations) {
            int from_byte = body.index_of_nth_char(loc.from_char);
            int to_byte = body.index_of_nth_char(loc.to_char);
            if (from_byte < 0 || to_byte < 0 || to_byte > body.length || from_byte > to_byte) continue;
            body = body.substring(0, from_byte) + body.substring(to_byte);
        }
    }
    return body;
}

private static string quote_json(Message m, Conversation conversation) {
    if (m.quoted_item_id <= 0) return "null";
    var quoted = app.stream_interactor.get_module(Dino.ContentItemStore.IDENTITY).get_item_by_id(conversation, m.quoted_item_id);
    if (quoted == null) return "null";
    string from = "";
    string body = "";
    var qmi = quoted as Dino.MessageItem;
    if (qmi != null) {
        from = Dino.get_participant_display_name(app.stream_interactor, conversation, qmi.message.from);
        body = display_body(qmi.message);
    } else {
        var qfi = quoted as Dino.FileItem;
        if (qfi != null) {
            from = qfi.file_transfer.from != null
                ? Dino.get_participant_display_name(app.stream_interactor, conversation, qfi.file_transfer.from) : "";
            body = qfi.file_transfer.file_name;
        }
    }
    if (body.char_count() > 100) body = body.substring(0, body.index_of_nth_char(100)) + "…";
    return "{\"item\":%d,\"from\":\"%s\",\"body\":\"%s\"}".printf(quoted.id, esc(from), esc(body));
}

private static string content_item_json(string type, Dino.ContentItem item, Conversation conversation) {
    var mi = item as Dino.MessageItem;
    if (mi != null) {
        Message m = mi.message;
        string direction = m.direction == Message.DIRECTION_SENT ? "out" : "in";
        bool editable = direction == "out" &&
            app.stream_interactor.get_module(Dino.MessageCorrection.IDENTITY).is_own_correction_allowed(conversation, m);
        string from_display = Dino.get_participant_display_name(app.stream_interactor, conversation, m.from);
        return "{\"type\":\"%s\",\"conversation\":%d,\"item\":%d,\"content\":\"text\",\"direction\":\"%s\",\"from\":\"%s\",\"from_display\":\"%s\",\"body\":\"%s\",\"time\":%lld,\"encryption\":\"%s\",\"editable\":%s,\"marked\":\"%s\",\"quote\":%s,\"reactions\":%s}".printf(
            type, conversation.id, item.id, direction, esc(m.from.to_string()), esc(from_display), esc(display_body(m)), m.time.to_unix(), enc_name(m.encryption),
            editable ? "true" : "false", marked_name(m.marked), quote_json(m, conversation), reactions_json(item, conversation));
    }
    var fi = item as Dino.FileItem;
    if (fi != null) {
        FileTransfer ft = fi.file_transfer;
        string direction = ft.direction == FileTransfer.DIRECTION_SENT ? "out" : "in";
        string path = "";
        if (ft.state == FileTransfer.State.COMPLETE) {
            File? f = ft.get_file();
            if (f != null && f.get_path() != null) path = f.get_path();
        }
        string ft_from = ft.from != null ? ft.from.to_string() : "";
        string ft_from_display = ft.from != null ? Dino.get_participant_display_name(app.stream_interactor, conversation, ft.from) : "";
        return "{\"type\":\"%s\",\"conversation\":%d,\"item\":%d,\"content\":\"file\",\"direction\":\"%s\",\"from\":\"%s\",\"from_display\":\"%s\",\"time\":%lld,\"encryption\":\"%s\",\"file_name\":\"%s\",\"mime\":\"%s\",\"size\":%lld,\"file_state\":\"%s\",\"path\":\"%s\",\"reactions\":%s}".printf(
            type, conversation.id, item.id, direction, esc(ft_from), esc(ft_from_display), item.time.to_unix(), enc_name(ft.encryption),
            esc(ft.file_name), esc(ft.mime_type ?? ""), ft.size, file_state_name(ft.state), esc(path), reactions_json(item, conversation));
    }
    return "{\"type\":\"%s\",\"conversation\":%d,\"item\":%d,\"content\":\"%s\",\"time\":%lld}".printf(
        type, conversation.id, item.id, esc(item.type_), item.time.to_unix());
}

// Room names normally come from disco#info after the MUC join completes;
// until then, fall back to the identity name cached in the database from a
// previous session so the conversation list is labelled immediately.
private static string? cached_room_name(Account account, Xmpp.Jid jid) {
    var db = app.db;
    string? hash = null;
    foreach (Qlite.Row row in db.entity.select()
            .with(db.entity.account_id, "=", account.id)
            .with(db.entity.jid_id, "=", db.get_jid_id(jid))
            .with(db.entity.resource, "=", jid.resourcepart ?? "")) {
        hash = row[db.entity.caps_hash];
        break;
    }
    if (hash == null) return null;
    foreach (Qlite.Row row in db.entity_identity.select()
            .with(db.entity_identity.entity, "=", hash)
            .with(db.entity_identity.category, "=", "conference")) {
        string name = row[db.entity_identity.entity_name];
        if (name != null && name != "") return name;
    }
    return null;
}

private static string conversation_json(Conversation c) {
    string name = Dino.get_conversation_display_name(app.stream_interactor, c, null);
    if (c.type_ == Conversation.Type.GROUPCHAT &&
            app.stream_interactor.get_module(Dino.MucManager.IDENTITY).get_room_name(c.account, c.counterpart) == null) {
        string? cached = cached_room_name(c.account, c.counterpart);
        if (cached != null && cached != c.counterpart.localpart) {
            name = cached;
        }
    }
    int unread = app.stream_interactor.get_module(Dino.ChatInteraction.IDENTITY).get_num_unread(c);
    string preview = "";
    string preview_direction = "";
    var latest = app.stream_interactor.get_module(Dino.ContentItemStore.IDENTITY).get_n_latest(c, 1);
    foreach (Dino.ContentItem item in latest) {
        var mi = item as Dino.MessageItem;
        if (mi != null) {
            preview = display_body(mi.message);
            preview_direction = mi.message.direction == Message.DIRECTION_SENT ? "out" : "in";
        } else {
            preview = "[file]";
        }
    }
    long last_time = c.last_active != null ? (long) c.last_active.to_unix() : 0;
    string kind = c.type_ == Conversation.Type.GROUPCHAT ? "groupchat" : "chat";
    return "{\"id\":%d,\"account\":\"%s\",\"jid\":\"%s\",\"name\":\"%s\",\"encryption\":\"%s\",\"kind\":\"%s\",\"unread\":%d,\"preview\":\"%s\",\"preview_direction\":\"%s\",\"time\":%ld,\"notify\":\"%s\",\"notify_effective\":\"%s\"}".printf(
        c.id, esc(c.account.bare_jid.to_string()), esc(c.counterpart.to_string()), esc(name), enc_name(c.encryption),
        kind, unread, esc(preview), preview_direction, last_time,
        notify_name(c.notify_setting), notify_name(c.get_notification_setting(app.stream_interactor)));
}

private static void push_avatar(Account account, Xmpp.Jid jid) {
    File? file = app.stream_interactor.get_module(Dino.AvatarManager.IDENTITY).get_avatar_file(account, jid);
    if (file != null && file.get_path() != null) {
        // keyed by the jid as requested: bare for contacts/rooms, full for
        // MUC occupants
        emit(@"{\"type\":\"avatar\",\"jid\":\"$(esc(jid.to_string()))\",\"path\":\"$(esc(file.get_path()))\"}");
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

// Re-emits a content item shortly after a change; the small delay lets
// libdino's async send/persist paths finish before the state is re-read.
private static void re_emit_item_delayed(int item_id) {
    Timeout.add(400, () => {
        re_emit_item(item_id);
        return Source.REMOVE;
    });
    // reaction/correction persistence completes after the stanza send, which
    // can take a network round-trip; emit again once that has settled
    Timeout.add(2000, () => {
        re_emit_item(item_id);
        return Source.REMOVE;
    });
    Timeout.add(5000, () => {
        re_emit_item(item_id);
        return Source.REMOVE;
    });
}

// Re-emits a content item given only its id by probing the active
// conversations (used from signals that don't carry the conversation).
private static void re_emit_item(int item_id) {
    // ContentItemStore.get_item_by_id does not check that the item belongs
    // to the conversation it is given, so resolve the owning conversation
    // from the database instead of probing.
    int conv_id = -1;
    foreach (Qlite.Row row in app.db.content_item.select().with(app.db.content_item.id, "=", item_id)) {
        conv_id = row[app.db.content_item.conversation_id];
        break;
    }
    if (conv_id == -1) return;
    Conversation? c = conversation_by_id(conv_id);
    if (c == null) return;
    var item = app.stream_interactor.get_module(Dino.ContentItemStore.IDENTITY).get_item_by_id(c, item_id);
    if (item != null) {
        emit(content_item_json("message", item, c));
    }
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
public void set_avatar(string path) {
    string p = path;
    Idle.add(() => {
        var account = first_enabled_account();
        if (account == null) return Source.REMOVE;
        app.stream_interactor.get_module(Dino.AvatarManager.IDENTITY).publish(account, p);
        return Source.REMOVE;
    });
}

public void set_alias(string alias) {
    string a = alias;
    Idle.add(() => {
        var account = first_enabled_account();
        if (account == null) return Source.REMOVE;
        account.alias = a;
        push_account_details();
        return Source.REMOVE;
    });
}

public void change_password(string new_password) {
    string pw = new_password;
    Idle.add(() => {
        var account = first_enabled_account();
        if (account == null) return Source.REMOVE;
        var register = app.stream_interactor.get_module(Dino.Register.IDENTITY);
        register.change_password.begin(account, pw, (_, res) => {
            string? condition = register.change_password.end(res);
            if (condition == null) {
                account.password = pw;
                emit("{\"type\":\"password_changed\"}");
            } else {
                emit(@"{\"type\":\"error\",\"message\":\"Password change failed: $(esc(condition))\"}");
            }
        });
        return Source.REMOVE;
    });
}

private static void push_account_details() {
    var account = first_enabled_account();
    if (account == null) return;
    int device_id = 0;
    string fingerprint = "";
#if WITH_OMEMO
    if (omemo_plugin != null) {
        var row = omemo_plugin.db.identity.row_with(omemo_plugin.db.identity.account_id, account.id).inner;
        if (row != null) {
            device_id = ((!)row)[omemo_plugin.db.identity.device_id];
            uint8[] key = Base64.decode(((!)row)[omemo_plugin.db.identity.identity_key_public_base64]);
            var b = new StringBuilder();
            // skip the djb type prefix byte, group hex in blocks of 8
            for (int i = 1; i < key.length; i++) {
                b.append_printf("%02x", key[i]);
                if (i % 4 == 0 && i != key.length - 1) b.append_c(' ');
            }
            fingerprint = b.str;
        }
    }
#endif
    emit("{\"type\":\"account_details\",\"jid\":\"%s\",\"alias\":\"%s\",\"omemo_device_id\":%d,\"omemo_fingerprint\":\"%s\"}".printf(
        esc(account.bare_jid.to_string()), esc(account.alias ?? ""), device_id, fingerprint));
}

// Enables XEP-0357 push notifications on the user's server, pointing at
// the push proxy. The node carries the APNs device token, so the proxy
// needs no registration state.
public void enable_push(string push_jid, string node) {
    string j = push_jid;
    string n = node;
    Idle.add(() => {
        var account = first_enabled_account();
        if (account == null) return Source.REMOVE;
        var stream = app.stream_interactor.get_stream(account);
        if (stream == null) {
            emit("{\"type\":\"push_state\",\"enabled\":false,\"reason\":\"not connected\"}");
            return Source.REMOVE;
        }
        try {
            var jid = new Xmpp.Jid(j);
            var module = stream.get_module(Xmpp.Xep.PushNotifications.Module.IDENTITY);
            module.enable.begin(stream, jid, n, (_, res) => {
                bool ok = module.enable.end(res);
                if (ok) {
                    push_proxy_jid = j;
                    push_token = n;
                    sync_push_filters();
                }
                emit(@"{\"type\":\"push_state\",\"enabled\":$(ok ? "true" : "false")}");
            });
        } catch (Error e) {
            emit(@"{\"type\":\"error\",\"message\":\"$(esc(e.message))\"}");
        }
        return Source.REMOVE;
    });
}

// Sends the per-conversation notification filters to the push proxy as a
// JSON message. The proxy applies them per device token; rules are re-sent
// on every (re-)enable so proxy restarts self-heal.
private static void sync_push_filters() {
    if (push_proxy_jid == null || push_token == null) return;
    var account = first_enabled_account();
    if (account == null) return;
    var stream = app.stream_interactor.get_stream(account);
    if (stream == null) return;

    var muted = new StringBuilder();
    var mention = new StringBuilder();
    foreach (Conversation c in app.stream_interactor.get_module(Dino.ConversationManager.IDENTITY).get_active_conversations()) {
        var effective = c.get_notification_setting(app.stream_interactor);
        if (effective == Conversation.NotifySetting.OFF) {
            if (muted.len > 0) muted.append_c(',');
            muted.append("\"%s\"".printf(esc(c.counterpart.bare_jid.to_string())));
        } else if (effective == Conversation.NotifySetting.HIGHLIGHT) {
            string nick = c.nickname ?? account.localpart;
            if (mention.len > 0) mention.append_c(',');
            mention.append("{\"jid\":\"%s\",\"nick\":\"%s\"}".printf(esc(c.counterpart.bare_jid.to_string()), esc(nick)));
        }
    }
    string json = "{\"gecko-push-filters\":1,\"token\":\"%s\",\"muted\":[%s],\"mention_only\":[%s]}".printf(
        push_token, muted.str, mention.str);

    try {
        // no body + no-store/no-copy hints: invisible to chat clients and
        // kept out of MAM/carbons
        var msg = new Xmpp.MessageStanza();
        msg.to = new Xmpp.Jid(push_proxy_jid);
        msg.type_ = Xmpp.MessageStanza.TYPE_NORMAL;
        var filters_node = new Xmpp.StanzaNode.build("filters", "urn:gecko:push:filters").add_self_xmlns();
        filters_node.put_node(new Xmpp.StanzaNode.text(json));
        msg.stanza.put_node(filters_node);
        msg.stanza.put_node(new Xmpp.StanzaNode.build("no-store", "urn:xmpp:hints").add_self_xmlns());
        msg.stanza.put_node(new Xmpp.StanzaNode.build("no-copy", "urn:xmpp:hints").add_self_xmlns());
        stream.get_module(Xmpp.MessageModule.IDENTITY).send_message.begin(stream, msg);
    } catch (Error e) {
        warning("Could not sync push filters: %s", e.message);
    }
}

// Ask the server to archive ALL messages (XEP-0313 prefs, default=always).
// prosody/xmpp.is otherwise only archives messages exchanged with roster
// contacts; with an empty roster that means 1:1 history is never written to
// MAM, so it never syncs when the app reconnects after being closed. Sent on
// each connect (idempotent).
private static void enable_mam_archiving(Account account) {
    var stream = app.stream_interactor.get_stream(account);
    if (stream == null) return;
    var prefs = new Xmpp.StanzaNode.build("prefs", "urn:xmpp:mam:2").add_self_xmlns();
    prefs.put_attribute("default", "always");
    var iq = new Xmpp.Iq.Stanza.set(prefs);
    stream.get_module(Xmpp.Iq.Module.IDENTITY).send_iq(stream, iq, (stream, result) => {
        string type = result.stanza.get_attribute("type") ?? "?";
        message("gecko: MAM default=always -> %s", type);
    });
}

public void set_notify(int conversation_id, string setting) {
    int cid = conversation_id;
    string sset = setting;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c == null) return Source.REMOVE;
        switch (sset) {
            case "on": c.notify_setting = Conversation.NotifySetting.ON; break;
            case "off": c.notify_setting = Conversation.NotifySetting.OFF; break;
            case "highlight": c.notify_setting = Conversation.NotifySetting.HIGHLIGHT; break;
            default: c.notify_setting = Conversation.NotifySetting.DEFAULT; break;
        }
        push_conversations();
        sync_push_filters();
        return Source.REMOVE;
    });
}

// Called when the app returns to the foreground: iOS freezes the process
// and kills sockets, so reconnect promptly instead of waiting for the
// regular retry cadence.
public void app_foregrounded() {
    Idle.add(() => {
        app.stream_interactor.connection_manager.resume_reconnect();
        return Source.REMOVE;
    });
}

public void request_account_details() {
    Idle.add(() => {
        push_account_details();
        return Source.REMOVE;
    });
}

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

public void send_text(int conversation_id, string body, int reply_to_item) {
    int cid = conversation_id; string text = body; int rid = reply_to_item;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c == null) {
            emit("{\"type\":\"error\",\"message\":\"Unknown conversation\"}");
            return Source.REMOVE;
        }
        Dino.send_message(c, text, rid, null, new Gee.ArrayList<Xmpp.Xep.MessageMarkup.Span>());
        return Source.REMOVE;
    });
}

public void set_reaction(int conversation_id, int item_id, string emoji, bool add) {
    int cid = conversation_id;
    int iid = item_id;
    string e = emoji;
    bool a = add;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c == null) return Source.REMOVE;
        var item = app.stream_interactor.get_module(Dino.ContentItemStore.IDENTITY).get_item_by_id(c, iid);
        if (item == null) return Source.REMOVE;
        var reactions = app.stream_interactor.get_module(Dino.Reactions.IDENTITY);
        if (a) reactions.add_reaction(c, item, e);
        else reactions.remove_reaction(c, item, e);
        re_emit_item_delayed(iid);
        return Source.REMOVE;
    });
}

public void correct_message(int conversation_id, int item_id, string body) {
    int cid = conversation_id;
    int iid = item_id;
    string text = body;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c == null) return Source.REMOVE;
        var mi = app.stream_interactor.get_module(Dino.ContentItemStore.IDENTITY).get_item_by_id(c, iid) as Dino.MessageItem;
        if (mi == null) return Source.REMOVE;
        if (!app.stream_interactor.get_module(Dino.MessageCorrection.IDENTITY).is_own_correction_allowed(c, mi.message)) {
            emit("{\"type\":\"error\",\"message\":\"This message can no longer be edited\"}");
            return Source.REMOVE;
        }
        Dino.send_message(c, text, 0, mi.message, new Gee.ArrayList<Xmpp.Xep.MessageMarkup.Span>());
        re_emit_item_delayed(iid);
        return Source.REMOVE;
    });
}

public void join_muc(string jid_str, string? nick) {
    string j = jid_str;
    string? n = nick == null || nick == "" ? null : nick;
    Idle.add(() => {
        try {
            var account = first_enabled_account();
            if (account == null) return Source.REMOVE;
            var jid = new Xmpp.Jid(j).bare_jid;
            var muc = app.stream_interactor.get_module(Dino.MucManager.IDENTITY);
            muc.join.begin(account, jid, n, null, false, null, (_, res) => {
                var result = muc.join.end(res);
                if (result == null) {
                    emit("{\"type\":\"error\",\"message\":\"Could not join: not connected\"}");
                } else if (result.nick == null) {
                    emit(@"{\"type\":\"error\",\"message\":\"Could not join $(esc(j))\"}");
                } else {
                    push_conversations();
                }
            });
        } catch (Error e) {
            emit(@"{\"type\":\"error\",\"message\":\"$(esc(e.message))\"}");
        }
        return Source.REMOVE;
    });
}

// Closes a conversation; for group chats this also leaves the room
// (removing the autojoin bookmark, like desktop Dino).
public void close_conversation(int conversation_id) {
    int cid = conversation_id;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c == null) return Source.REMOVE;
        if (c.type_ == Conversation.Type.GROUPCHAT) {
            app.stream_interactor.get_module(Dino.MucManager.IDENTITY).part(c.account, c.counterpart);
        }
        app.stream_interactor.get_module(Dino.ConversationManager.IDENTITY).close_conversation(c);
        push_conversations();
        return Source.REMOVE;
    });
}

public void request_occupants(int conversation_id) {
    int cid = conversation_id;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c == null) return Source.REMOVE;
        var muc = app.stream_interactor.get_module(Dino.MucManager.IDENTITY);
        var occupants = muc.get_occupants(c.counterpart, c.account);
        Xmpp.Jid? own = muc.get_own_jid(c.counterpart, c.account);
        var b = new StringBuilder();
        b.append_printf("{\"type\":\"occupants\",\"conversation\":%d,\"list\":[", cid);
        bool first = true;
        if (occupants != null) {
            foreach (Xmpp.Jid occupant in occupants) {
                if (occupant.resourcepart == null) continue;
                if (!first) b.append_c(',');
                first = false;
                bool is_self = own != null && own.equals(occupant);
                b.append("{\"nick\":\"%s\",\"self\":%s}".printf(esc(occupant.resourcepart), is_self ? "true" : "false"));
            }
        }
        b.append("]}");
        emit(b.str);
        return Source.REMOVE;
    });
}

public void send_file(int conversation_id, string path) {
    int cid = conversation_id;
    string p = path;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c == null) {
            emit("{\"type\":\"error\",\"message\":\"Unknown conversation\"}");
            return Source.REMOVE;
        }
        var fm = app.stream_interactor.get_module(Dino.FileManager.IDENTITY);
        fm.is_upload_available.begin(c, (_, res) => {
            if (!fm.is_upload_available.end(res)) {
                emit("{\"type\":\"error\",\"message\":\"File upload is not available on this server\"}");
                return;
            }
            fm.send_file.begin(File.new_for_path(p), c);
        });
        return Source.REMOVE;
    });
}

public void download_file(int conversation_id, int item_id) {
    int cid = conversation_id;
    int iid = item_id;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c == null) return Source.REMOVE;
        var item = app.stream_interactor.get_module(Dino.ContentItemStore.IDENTITY).get_item_by_id(c, iid);
        var fi = item as Dino.FileItem;
        if (fi == null) return Source.REMOVE;
        // re-emit the item when the transfer state changes so the UI updates
        fi.file_transfer.notify["state"].connect(() => {
            emit(content_item_json("message", fi, c));
        });
        app.stream_interactor.get_module(Dino.FileManager.IDENTITY).download_file.begin(fi.file_transfer);
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
            push_avatar(account, new Xmpp.Jid(j));
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
