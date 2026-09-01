// Apple-platform bridge for Gecko: boots the full libdino service stack
// (database, stream interactor, all managers) without any GTK dependency and
// exposes a small C API for the SwiftUI shell.
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
private static bool nse_mode = false;
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
    string resource_prefix = "gecko";
#if MAC_CATALYST
    resource_prefix = "gecko-mac";
    // Catalyst is a persistent desktop process: use normal connectivity
    // monitoring and allow XEP-0198 to resume transient network interruptions.
    // The notification extension remains short-lived and must never leave a
    // resumable session behind.
    app.stream_interactor.connection_manager.use_network_monitor = !nse_mode;
    Dino.ModuleManager.client_identity_name = "Gecko";
    Dino.ModuleManager.client_identity_type = "pc";
    Xmpp.Xep.StreamManagement.Module.request_resumption = !nse_mode;
#else
    // GLib's NetworkMonitor misreads iOS connectivity (reads offline/flapping),
    // which otherwise drives the ConnectionManager to force every account
    // DISCONNECTED right after it connects — breaking sends and MUC joins.
    // iOS connectivity is handled by the app lifecycle + reconnect timers.
    app.stream_interactor.connection_manager.use_network_monitor = false;
    Dino.ModuleManager.client_identity_name = "Gecko";
    Dino.ModuleManager.client_identity_type = "phone";
    // Never request XEP-0198 resumption on iOS. The app process is killed when
    // backgrounded, losing the in-memory SM session id, so resumption can never
    // actually resume — instead each launch leaves a hibernated "ghost" session
    // on the server that holds presence and repeatedly fires push notifications.
    Xmpp.Xep.StreamManagement.Module.request_resumption = false;
#endif
    Account.resource_prefix = resource_prefix;
    // migrate pre-rename resources before restore() loads the accounts
    foreach (Qlite.Row row in app.db.account.select()) {
        string? res = row[app.db.account.resourcepart];
        if (res != null && res.has_prefix("dino.")) {
            app.db.account.update()
                .with(app.db.account.id, "=", row[app.db.account.id])
                .set(app.db.account.resourcepart, resource_prefix + "." + res.substring(5))
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
    });
}

// --- Notification Service Extension fetch path ---------------------------
// The NSE boots the stack, lets the enabled account connect and MAM-sync,
// and collects the incoming messages that arrive within its time budget,
// then returns a single {"type":"nse_result","messages":[...]} line. Each
// message carries everything the extension needs to decide on-device:
// conversation, sender, decrypted body, the conversation's effective notify
// setting, and whether it mentions the user.

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
    return "{\"conversation\":%d,\"jid\":\"%s\",\"conversation_name\":\"%s\",\"from\":\"%s\",\"body\":\"%s\",\"encrypted\":%s,\"notify\":\"%s\",\"groupchat\":%s,\"mentioned\":%s,\"time\":%lld}".printf(
        c.id, esc(c.counterpart.to_string()), esc(conv_name), esc(from_display), esc(body),
        m.encryption != Encryption.NONE ? "true" : "false",
        notify_name(effective), is_group ? "true" : "false",
        mentioned ? "true" : "false", m.time.to_unix());
}

// NB: there is deliberately NO DB fallback when the live fetch collects
// nothing. The push carries no message id, so the extension can't tell *which*
// stored message this push is about — falling back to "the latest decrypted
// message" confidently shows the WRONG (often already-seen) message, which
// reads as a duplicate/stale banner. Better to return nothing and let the Swift
// side show a generic "New message" than to resurrect an old one. Precise
// per-message classification (incl. muted-suppression) needs the filtering
// entitlement; until then, decrypt-live-or-generic is the honest behaviour.

private static void nse_finish() {
    if (nse_done) return;
    nse_done = true;
    if (nse_settle != 0) { Source.remove(nse_settle); nse_settle = 0; }
    nse_msgs.append_c(']');
    string result = @"{\"type\":\"nse_result\",\"messages\":$(nse_msgs.str)}";
    // Close the XMPP session cleanly BEFORE signalling the extension is done.
    // emit() drives the NSE's contentHandler, after which iOS can suspend/kill
    // the extension at any instant. If that happens before our ack +
    // unavailable presence + </stream:stream> are written, the session closes
    // UNCLEANLY and the server hibernates it into a "ghost" that re-fires a push
    // for every later message — one extra push per leaked session (the
    // escalating-duplicates bug). So tear down first, emit second.
    nse_shutdown.begin((_, res) => {
        nse_shutdown.end(res);
        emit(result);
        if (app != null) app.quit();
    });
}

private static async void nse_shutdown() {
    try {
        var cm = app.stream_interactor.connection_manager;
        foreach (Account account in app.db.get_accounts()) {
            if (!account.enabled) continue;
            Xmpp.XmppStream? stream = cm.get_stream(account);
            if (stream != null) {
                var sm = stream.get_module(Xmpp.Xep.StreamManagement.Module.IDENTITY);
                if (sm != null) {
                    try { yield sm.flush_ack(stream); } catch (Error e) {}
                }
            }
            yield cm.disconnect_account(account);
        }
    } catch (Error e) {
        warning("nse shutdown error: %s", e.message);
    }
    // app.quit() happens in nse_finish's callback, after we emit the result —
    // so the clean teardown above always completes before the extension is told
    // it's done (and iOS can reap it).
}

public void nse_fetch(int timeout_ms, owned EventCb cb) {
    event_cb = (owned) cb;
    int hard_ms = timeout_ms;
    new Thread<bool>("dino-nse", () => {
        nse_msgs = new StringBuilder("[");
        nse_done = false;
        nse_first = true;
        nse_settle = 0;
        nse_seen = new Gee.HashSet<string>();
        nse_mode = true;
        // Don't request XEP-0198 resumption: the extension's session is
        // short-lived, and a resumable (hibernated) session left on the server
        // re-pushes its held message forever. Without resumption the session
        // ends on disconnect and any undelivered message falls back to normal
        // offline storage, which pushes once rather than on a loop.
        Xmpp.Xep.StreamManagement.Module.request_resumption = false;
        try {
            boot_core();
        } catch (Error e) {
            emit(@"{\"type\":\"nse_result\",\"error\":\"$(esc(e.message))\",\"messages\":[]}");
            return false;
        }
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
            // Ack received stanzas NOW (XEP-0198), not just at shutdown: the
            // server clears its push-pending state when it sees our <a/>, so
            // acking immediately beats its re-push grace timer. Acking only on
            // shutdown (after the 2.5s settle) lets that timer fire first and
            // emit a second "ghost" push for the same message.
            var ack_stream = app.stream_interactor.connection_manager.get_stream(conversation.account);
            if (ack_stream != null) {
                var ack_sm = ack_stream.get_module(Xmpp.Xep.StreamManagement.Module.IDENTITY);
                if (ack_sm != null) ack_sm.flush_ack.begin(ack_stream);
            }
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
                    // Resource was already set to the stable "gecko-nse" before
                    // app.run() (so restore() bound it correctly); this explicit
                    // connect is a backstop in case restore() didn't fire.
                    app.stream_interactor.connect_account(account);
                    n++;
                }
            }
            return Source.REMOVE;
        });
        // Force a STABLE, per-install, app-distinct resource BEFORE app.run()
        // fires the `startup` signal -> restore() -> add_connection(), which
        // would otherwise bind with the db-stored (and periodically
        // regenerated) "gecko.<hex>" resource. A fresh random resource per wake
        // left a new server-side session each time; with resume/push that
        // orphans a push-enabled session that re-pushes forever. The resource
        // must be STABLE across wakes (so a repeat wake resource-conflict-
        // *replaces* its own previous session instead of orphaning a new one)
        // and UNIQUE per install (so multiple installs' extensions don't kick
        // each other). Swift hands us a per-install id via GECKO_NSE_RESOURCE.
        // db.get_accounts() returns cached instances, so restore() sees these.
        string nse_resource = Environment.get_variable("GECKO_NSE_RESOURCE") ?? "gecko-nse";
        foreach (Account account in app.db.get_accounts()) {
            if (account.enabled) account.set_ephemeral_resource(nse_resource);
        }
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
            if (state == Dino.ConnectionManager.ConnectionState.CONNECTED) {
                enable_mam_archiving(account);
                // Re-assert the user's chosen presence after Dino's initial
                // available presence, so away/dnd + status survive reconnects.
                if ((self_show ?? "online") != "online" || (self_status ?? "") != "") apply_self_presence();
            }
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
            emit(chat_state_json(conversation, state));
        });
        si.get_module(Dino.AvatarManager.IDENTITY).received_avatar.connect((jid, account) => {
            push_avatar(account, jid);
        });
        // A newly-announced avatar isn't on disk yet — get_avatar_file kicks off
        // an async fetch and returns null. fetched_avatar fires once it lands, so
        // push again then (otherwise e.g. a freshly-set room avatar never shows).
        si.get_module(Dino.AvatarManager.IDENTITY).fetched_avatar.connect((jid, account) => {
            push_avatar(account, jid);
        });
        si.get_module(Dino.ConversationManager.IDENTITY).conversation_activated.connect((conversation) => {
            push_conversations();
        });
        // Re-emit room state when the server broadcasts a change (subject, or a
        // config/feature update) so an open Room Details screen updates live
        // with fresh data — the values we'd read right after set_config_form are
        // still cached/stale.
        var muc_mod = si.get_module(Dino.MucManager.IDENTITY);
        muc_mod.subject_set.connect((account, jid, subject) => {
            // jid is the sender (room@conf/nick); the conversation is keyed by
            // the bare room jid.
            var conv = si.get_module(Dino.ConversationManager.IDENTITY).get_conversation(jid.bare_jid, account, Conversation.Type.GROUPCHAT);
            if (conv != null) emit_room_info(conv);
        });
        muc_mod.room_info_updated.connect((account, jid) => {
            var conv = si.get_module(Dino.ConversationManager.IDENTITY).get_conversation(jid.bare_jid, account, Conversation.Type.GROUPCHAT);
            if (conv != null) { emit_room_info(conv); push_conversations(); }
        });
        muc_mod.left.connect((account, room, code) => {
            var conv = si.get_module(Dino.ConversationManager.IDENTITY)
                .get_conversation(room.bare_jid, account, Conversation.Type.GROUPCHAT);
            if (conv != null) {
                emit(@"{\"type\":\"muc_removed\",\"conversation\":$(conv.id),\"account\":\"$(esc(account.bare_jid.to_string()))\",\"room\":\"$(esc(room.bare_jid.to_string()))\",\"reason\":\"$(muc_removal_reason(code))\"}");
            }
            push_conversations();
        });
        muc_mod.invite_received.connect((account, room, inviter, password, reason) => {
            if (has_active_groupchat(account, room)) return;
            emit(@"{\"type\":\"muc_invite\",\"account\":\"$(esc(account.bare_jid.to_string()))\",\"room\":\"$(esc(room.bare_jid.to_string()))\",\"inviter\":\"$(esc(inviter.bare_jid.to_string()))\",\"password\":\"$(esc(password ?? ""))\",\"reason\":\"$(esc(reason ?? ""))\"}");
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
        si.get_module(Dino.PresenceManager.IDENTITY).show_received.connect((jid, account) => {
            push_roster();
            // A MUC occupant came online (joined / presence change) — refresh
            // the participant list live.
            if (si.get_module(Dino.MucManager.IDENTITY).is_groupchat(jid.bare_jid, account)) {
                schedule_occupants_refresh(account, jid.bare_jid);
            }
        });
        si.get_module(Dino.PresenceManager.IDENTITY).received_offline_presence.connect((jid, account) => {
            push_roster();
            if (si.get_module(Dino.MucManager.IDENTITY).is_groupchat(jid.bare_jid, account)) {
                schedule_occupants_refresh(account, jid.bare_jid);  // occupant left
            }
        });
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
        string body = display_body(m);
        bool mentioned = false;
        if (conversation.type_ == Conversation.Type.GROUPCHAT) {
            string? nick = conversation.nickname ?? conversation.account.localpart;
            if (nick != null && nick != "") mentioned = body.down().contains(nick.down());
        }
        string mentioned_json = mentioned ? "true" : "false";
        return "{\"type\":\"%s\",\"conversation\":%d,\"item\":%d,\"content\":\"text\",\"direction\":\"%s\",\"from\":\"%s\",\"from_display\":\"%s\",\"body\":\"%s\",\"mentioned\":%s,\"time\":%lld,\"encryption\":\"%s\",\"editable\":%s,\"marked\":\"%s\",\"synced\":%s,\"quote\":%s,\"reactions\":%s}".printf(
            type, conversation.id, item.id, direction, esc(m.from.to_string()), esc(from_display), esc(body), mentioned_json, item.time.to_unix(), enc_name(m.encryption),
            editable ? "true" : "false", marked_name(m.marked), m.is_mam_message ? "true" : "false", quote_json(m, conversation), reactions_json(item, conversation));
    }
    var fi = item as Dino.FileItem;
    if (fi != null) {
        FileTransfer ft = fi.file_transfer;
        string direction = ft.direction == FileTransfer.DIRECTION_SENT ? "out" : "in";
        string path = "";
        // Sent files are copied into Dino's storage before upload starts, so
        // their local path remains valid while IN_PROGRESS. Incoming paths are
        // exposed only after the download has completed.
        if (ft.direction == FileTransfer.DIRECTION_SENT || ft.state == FileTransfer.State.COMPLETE) {
            File? f = ft.get_file();
            if (f != null && f.get_path() != null) path = f.get_path();
        }
        string ft_from = ft.from != null ? ft.from.to_string() : "";
        string ft_from_display = ft.from != null ? Dino.get_participant_display_name(app.stream_interactor, conversation, ft.from) : "";
        return "{\"type\":\"%s\",\"conversation\":%d,\"item\":%d,\"content\":\"file\",\"direction\":\"%s\",\"from\":\"%s\",\"from_display\":\"%s\",\"time\":%lld,\"encryption\":\"%s\",\"file_name\":\"%s\",\"mime\":\"%s\",\"size\":%lld,\"file_state\":\"%s\",\"path\":\"%s\",\"synced\":%s,\"reactions\":%s}".printf(
            type, conversation.id, item.id, direction, esc(ft_from), esc(ft_from_display), item.time.to_unix(), enc_name(ft.encryption),
            esc(ft.file_name), esc(ft.mime_type ?? ""), ft.size, file_state_name(ft.state), esc(path), ft.is_mam_message ? "true" : "false", reactions_json(item, conversation));
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
    return "{\"id\":%d,\"account\":\"%s\",\"jid\":\"%s\",\"name\":\"%s\",\"encryption\":\"%s\",\"encryption_available\":%s,\"kind\":\"%s\",\"unread\":%d,\"preview\":\"%s\",\"preview_direction\":\"%s\",\"time\":%ld,\"notify\":\"%s\",\"notify_effective\":\"%s\"}".printf(
        c.id, esc(c.account.bare_jid.to_string()), esc(c.counterpart.to_string()), esc(name), enc_name(c.encryption),
        encryption_available(c) ? "true" : "false",
        kind, unread, esc(preview), preview_direction, last_time,
        notify_name(c.notify_setting), notify_name(c.get_notification_setting(app.stream_interactor)));
}

// A private room is members-only + non-anonymous. We read this from the MUC
// flag (refreshed by the room's config-change disco) rather than
// MucManager.is_private_room, which reads EntityInfo's separate caps cache that
// only catches up later — that lag made the Private toggle revert after a set.
private static bool room_is_private(Conversation c) {
    var stream = app.stream_interactor.connection_manager.get_stream(c.account);
    if (stream == null) return false;
    var flag = stream.get_flag(Xmpp.Xep.Muc.Flag.IDENTITY);
    if (flag == null) return false;
    return flag.has_room_feature(c.counterpart, Xmpp.Xep.Muc.Feature.MEMBERS_ONLY)
        && flag.has_room_feature(c.counterpart, Xmpp.Xep.Muc.Feature.NON_ANONYMOUS);
}

// Whether OMEMO can be turned on for this conversation. In a group chat it
// requires a private room (members-only + non-anonymous) so occupants' real
// JIDs are visible to fetch their device keys; a groupchat PM can't be
// encrypted; 1:1 chats always can.
private static bool encryption_available(Conversation c) {
#if WITH_OMEMO
    switch (c.type_) {
        case Conversation.Type.GROUPCHAT:
            return room_is_private(c);
        case Conversation.Type.GROUPCHAT_PM:
            return false;
        default:
            return true;
    }
#else
    return false;
#endif
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

private static Account? enabled_account_by_jid(string jid) {
    foreach (Account account in app.db.get_accounts()) {
        if (account.enabled && account.bare_jid.to_string() == jid) return account;
    }
    return null;
}

private static bool has_active_groupchat(Account account, Xmpp.Jid room) {
    foreach (Conversation conversation in app.stream_interactor
            .get_module(Dino.ConversationManager.IDENTITY).get_active_conversations()) {
        if (conversation.type_ == Conversation.Type.GROUPCHAT &&
                conversation.account.equals(account) &&
                conversation.counterpart.bare_jid.to_string() == room.bare_jid.to_string()) {
            return true;
        }
    }
    return false;
}

private static string muc_removal_reason(Xmpp.Xep.Muc.StatusCode code) {
    switch (code) {
        case Xmpp.Xep.Muc.StatusCode.BANNED:
            return "banned";
        case Xmpp.Xep.Muc.StatusCode.KICKED:
            return "kicked";
        case Xmpp.Xep.Muc.StatusCode.REMOVED_AFFILIATION_CHANGE:
            return "affiliation_changed";
        case Xmpp.Xep.Muc.StatusCode.REMOVED_MEMBERS_ONLY:
            return "members_only";
        case Xmpp.Xep.Muc.StatusCode.REMOVED_SHUTDOWN:
            return "shutdown";
        default:
            return "removed";
    }
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

private static string typing_names_json(Conversation c, out bool has_typing) {
    has_typing = false;
    Gee.List<Xmpp.Jid>? jids = app.stream_interactor
        .get_module(Dino.CounterpartInteractionManager.IDENTITY)
        .get_typing_jids(c);
    if (jids == null || jids.size == 0) return "[]";

    var b = new StringBuilder("[");
    bool first = true;
    foreach (Xmpp.Jid jid in jids) {
        string name = Dino.get_participant_display_name(app.stream_interactor, c, jid);
        if (!first) b.append_c(',');
        first = false;
        has_typing = true;
        b.append("\"%s\"".printf(esc(name)));
    }
    b.append("]");
    return b.str;
}

private static string chat_state_json(Conversation c, string state) {
    bool has_typing;
    string names = typing_names_json(c, out has_typing);
    string effective_state = has_typing ? Xmpp.Xep.ChatStateNotifications.STATE_COMPOSING : state;
    return "{\"type\":\"chat_state\",\"conversation\":%d,\"state\":\"%s\",\"typing_names\":%s}".printf(
        c.id, esc(effective_state), names);
}

private static bool is_temp_staging_path(string path) {
    string tmp = Environment.get_tmp_dir();
    string prefix = tmp.has_suffix("/") ? tmp : tmp + "/";
    return path.has_prefix(prefix);
}

private static void remove_temp_staging_path(string path) {
    if (is_temp_staging_path(path)) FileUtils.remove(path);
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

// --- Privacy (typing notifications + read markers, XEP-0085/0333) ---------
// These map to libdino's global Settings, which the send paths already honor.

private static void emit_privacy() {
    emit("{\"type\":\"privacy\",\"send_typing\":%s,\"send_marker\":%s}".printf(
        app.settings.send_typing ? "true" : "false",
        app.settings.send_marker ? "true" : "false"));
}

public void request_privacy() {
    Idle.add(() => { emit_privacy(); return Source.REMOVE; });
}

public void set_send_typing(bool on) {
    bool v = on;
    Idle.add(() => { app.settings.send_typing = v; emit_privacy(); return Source.REMOVE; });
}

public void set_send_marker(bool on) {
    bool v = on;
    Idle.add(() => { app.settings.send_marker = v; emit_privacy(); return Source.REMOVE; });
}

// The roster gives bare jids, but presence is stored per resource (full jid),
// so get_last_show(bare) is always null. Resolve the contact's resources and
// return the most-available show: "online" | "away" | "xa" | "dnd" | "offline".
private static string roster_show(Dino.PresenceManager presence, Xmpp.Jid bare, Account a) {
    var resources = presence.get_full_jids(bare, a);
    if (resources == null || resources.size == 0) return "offline";
    string best = "offline";
    int best_rank = -1;
    foreach (Xmpp.Jid full in resources) {
        string s = presence.get_last_show(full, a) ?? "";  // "" == available
        int rank;
        switch (s) {
            case "": case "chat": rank = 4; break;  // online
            case "dnd": rank = 3; break;
            case "away": rank = 2; break;
            case "xa": rank = 1; break;
            default: rank = 0; break;
        }
        if (rank > best_rank) {
            best_rank = rank;
            best = (s == "" || s == "chat") ? "online" : s;
        }
    }
    return best;
}

// The user's own chosen presence for this session (null/"online" means no
// <show>). Re-applied after each (re)connect; resets to online on app restart.
private static string? self_show = null;
private static string? self_status = null;

private static void apply_self_presence() {
    string show = self_show ?? "online";
    string status = self_status ?? "";
    foreach (Account a in app.db.get_accounts()) {
        if (!a.enabled) continue;
        var stream = app.stream_interactor.connection_manager.get_stream(a);
        if (stream == null) continue;
        var presence = new Xmpp.Presence.Stanza();
        presence.type_ = Xmpp.Presence.Stanza.TYPE_AVAILABLE;
        if (show != "online" && show != "") presence.show = show;
        if (status != "") presence.status = status;
        stream.get_module(Xmpp.Presence.Module.IDENTITY).send_presence(stream, presence);
    }
}

private static void emit_self_presence() {
    emit("{\"type\":\"self_presence\",\"show\":\"%s\",\"status\":\"%s\"}".printf(
        esc(self_show ?? "online"), esc(self_status ?? "")));
}

// show: "online" | "away" | "dnd" | "xa"
public void set_presence(string show, string status) {
    string sh = show;
    string st = status;
    Idle.add(() => {
        self_show = sh;
        self_status = st;
        apply_self_presence();
        emit_self_presence();
        return Source.REMOVE;
    });
}

public void request_self_presence() {
    Idle.add(() => { emit_self_presence(); return Source.REMOVE; });
}

// --- Blocking (XEP-0191) --------------------------------------------------

private static void emit_blocklist() {
    var account = first_enabled_account();
    var b = new StringBuilder("{\"type\":\"blocklist\",\"supported\":");
    bool supported = account != null
        && app.stream_interactor.get_module(Dino.BlockingManager.IDENTITY).is_supported(account);
    b.append(supported ? "true" : "false");
    b.append(",\"list\":[");
    bool first = true;
    if (account != null) {
        var stream = app.stream_interactor.connection_manager.get_stream(account);
        if (stream != null) {
            var flag = stream.get_flag(Xmpp.Xep.BlockingCommand.Flag.IDENTITY);
            if (flag != null && flag.blocklist != null) {
                foreach (string jid in flag.blocklist) {
                    if (!first) b.append_c(',');
                    first = false;
                    b.append("\"%s\"".printf(esc(jid)));
                }
            }
        }
    }
    b.append("]}");
    emit(b.str);
}

public void request_blocklist() {
    Idle.add(() => { emit_blocklist(); return Source.REMOVE; });
}

public void block_contact(string jid_str) {
    string j = jid_str;
    Idle.add(() => {
        var account = first_enabled_account();
        if (account == null) return Source.REMOVE;
        try {
            app.stream_interactor.get_module(Dino.BlockingManager.IDENTITY).block(account, new Xmpp.Jid(j));
        } catch (Error e) {
            emit(@"{\"type\":\"error\",\"message\":\"$(esc(e.message))\"}");
        }
        // The server confirms via a block push that updates the flag; re-emit
        // once it's likely arrived.
        Timeout.add(600, () => { emit_blocklist(); return Source.REMOVE; });
        return Source.REMOVE;
    });
}

public void unblock_contact(string jid_str) {
    string j = jid_str;
    Idle.add(() => {
        var account = first_enabled_account();
        if (account == null) return Source.REMOVE;
        try {
            app.stream_interactor.get_module(Dino.BlockingManager.IDENTITY).unblock(account, new Xmpp.Jid(j));
        } catch (Error e) {
            emit(@"{\"type\":\"error\",\"message\":\"$(esc(e.message))\"}");
        }
        Timeout.add(600, () => { emit_blocklist(); return Source.REMOVE; });
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
            b.append("{\"account\":\"%s\",\"jid\":\"%s\",\"name\":\"%s\",\"subscription\":\"%s\",\"show\":\"%s\"}".printf(
                esc(a.bare_jid.to_string()), esc(item.jid.to_string()), esc(item.name ?? ""),
                esc(item.subscription ?? ""), esc(roster_show(presence, item.jid, a))));
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

// Publish a room avatar (XEP-0153 vCard-temp PHOTO on the room jid). Only owners
// may set it — the UI gates on that and the service rejects it otherwise. After
// the set, the service broadcasts the new photo hash in room presence and the
// normal avatar pipeline picks it up; we also write the scaled PNG to a temp
// file and push it straight away so the owner sees the change without waiting.
public void muc_set_avatar(int conversation_id, string path) {
    int cid = conversation_id;
    string p = path;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c == null || c.type_ != Conversation.Type.GROUPCHAT) return Source.REMOVE;
        var stream = app.stream_interactor.get_stream(c.account);
        if (stream == null) return Source.REMOVE;
        try {
            var pixbuf = new Gdk.Pixbuf.from_file(p);
            const int MAX = 192;
            if (pixbuf.width > MAX || pixbuf.height > MAX) {
                int w, h;
                if (pixbuf.width >= pixbuf.height) {
                    w = MAX; h = (int) ((float) MAX / pixbuf.width * pixbuf.height);
                } else {
                    h = MAX; w = (int) ((float) MAX / pixbuf.height * pixbuf.width);
                }
                pixbuf = pixbuf.scale_simple(w, h, Gdk.InterpType.BILINEAR);
            }
            uint8[] buffer;
            pixbuf.save_to_buffer(out buffer, "png");

            var photo = new Xmpp.StanzaNode.build("PHOTO", "vcard-temp");
            photo.put_node(new Xmpp.StanzaNode.build("TYPE", "vcard-temp").put_node(new Xmpp.StanzaNode.text("image/png")));
            photo.put_node(new Xmpp.StanzaNode.build("BINVAL", "vcard-temp").put_node(new Xmpp.StanzaNode.text(Base64.encode(buffer))));
            var vcard = new Xmpp.StanzaNode.build("vCard", "vcard-temp").add_self_xmlns();
            vcard.put_node(photo);
            var iq = new Xmpp.Iq.Stanza.set(vcard) { to = c.counterpart };
            stream.get_module(Xmpp.Iq.Module.IDENTITY).send_iq(stream, iq, (stream, result) => {
                message("gecko: MUC vCard avatar set -> %s", result.stanza.get_attribute("type") ?? "?");
            });

            string tmp = Path.build_filename(Environment.get_tmp_dir(),
                "gecko-room-avatar-%u.png".printf(c.counterpart.to_string().hash()));
            FileUtils.set_data(tmp, buffer);
            emit(@"{\"type\":\"avatar\",\"jid\":\"$(esc(c.counterpart.to_string()))\",\"path\":\"$(esc(tmp))\"}");
        } catch (Error e) {
            warning("gecko: muc_set_avatar failed: %s", e.message);
        }
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
            // Clear ALL existing registrations for this push service first, then
            // register exactly one. Re-enabling without this accumulates stale
            // registrations on the server (each makes it publish again -> the
            // same message arrives as several pushes, and stale phantom state
            // keeps re-pushing). disable(node=null) wipes them for a clean slate.
            module.disable.begin(stream, jid, null, (_, dres) => {
                module.disable.end(dres);
                module.enable.begin(stream, jid, n, (_, res) => {
                    bool ok = module.enable.end(res);
                    if (ok) {
                        push_proxy_jid = j;
                        push_token = n;
                        sync_push_filters();
                    }
                    emit(@"{\"type\":\"push_state\",\"enabled\":$(ok ? "true" : "false")}");
                });
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
// regular retry cadence. connect_account re-establishes a fresh connection
// for any account the background handler cleanly disconnected (it was unset
// from the manager), and falls back to check_reconnect for ones still managed.
public void app_foregrounded() {
    Idle.add(() => {
        foreach (Account account in app.db.get_accounts()) {
            if (account.enabled) app.stream_interactor.connect_account(account);
        }
        app.stream_interactor.connection_manager.resume_reconnect();
        return Source.REMOVE;
    });
}

// Called when the app enters the background. iOS will suspend the process
// shortly, freezing the XMPP socket with any just-received message still
// unacked — the server then treats that c2s session as pending and re-pushes
// the message every couple of seconds (the same mechanism as the old phantom
// loop, but for a real message; mod_push_keepalive keeps it alive for hours).
// Tear the session down cleanly instead: flush XEP-0198 acks so nothing is
// pending, then disconnect (unavailable presence + close). With resumption
// disabled the session ends outright (no hibernated ghost), so the server
// delivers subsequent messages to the NSE's session (which acks them) or to
// offline storage — one push per message. The app reconnects on foreground.
public void app_backgrounded() {
    app_disconnect_clean.begin();
}

private static async void app_disconnect_clean() {
    try {
        var cm = app.stream_interactor.connection_manager;
        foreach (Account account in app.db.get_accounts()) {
            if (!account.enabled) continue;
            Xmpp.XmppStream? stream = cm.get_stream(account);
            if (stream != null) {
                var sm = stream.get_module(Xmpp.Xep.StreamManagement.Module.IDENTITY);
                if (sm != null) {
                    try { yield sm.flush_ack(stream); } catch (Error e) {}
                }
            }
            yield cm.disconnect_account(account);
        }
    } catch (Error e) {
        emit(@"{\"type\":\"app_background_error\",\"msg\":\"$(esc(e.message))\"}");
    }
    emit("{\"type\":\"app_backgrounded\"}");
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
        string next_before = items.size > 0 ? items.get(0).id.to_string() : "null";
        var b = new StringBuilder();
        b.append_printf("{\"type\":\"history\",\"conversation\":%d,\"complete\":%s,\"next_before\":%s,\"items\":[",
            cid, items.size < n ? "true" : "false", next_before);
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

public void request_messages_before(int conversation_id, int before_item_id, int count) {
    int cid = conversation_id; int before_id = before_item_id; int n = count;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c == null) return Source.REMOVE;
        var store = app.stream_interactor.get_module(Dino.ContentItemStore.IDENTITY);
        Dino.ContentItem? before = store.get_item_by_id(c, before_id);
        if (before == null) {
            emit("{\"type\":\"history_before\",\"conversation\":%d,\"before\":%d,\"complete\":true,\"next_before\":null,\"items\":[]}"
                .printf(cid, before_id));
            return Source.REMOVE;
        }
        var items = store.get_before(c, before, n);
        string next_before = items.size > 0 ? items.get(0).id.to_string() : "null";
        var b = new StringBuilder();
        b.append_printf("{\"type\":\"history_before\",\"conversation\":%d,\"before\":%d,\"complete\":%s,\"next_before\":%s,\"items\":[",
            cid, before_id, items.size < n ? "true" : "false", next_before);
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
            // Probe whether the room already exists via disco#info. Joining a
            // non-existent JID would have the server create it (see
            // do_join_muc) — fine if intended, but a typo would silently spawn
            // a real persistent room, so ask the UI to confirm creation first.
            var entity_info = app.stream_interactor.get_module(Dino.EntityInfo.IDENTITY);
            entity_info.get_identities.begin(account, jid, (_, res) => {
                var identities = entity_info.get_identities.end(res);
                bool exists = identities != null && identities.size > 0;
                if (exists) {
                    do_join_muc(account, jid, n, null, false);
                } else {
                    emit(@"{\"type\":\"confirm_create_muc\",\"jid\":\"$(esc(jid.to_string()))\",\"nick\":\"$(esc(n ?? ""))\"}");
                }
            });
        } catch (Error e) {
            emit(@"{\"type\":\"error\",\"message\":\"$(esc(e.message))\"}");
        }
        return Source.REMOVE;
    });
}

public void accept_muc_invite(string account_str, string room_str, string? password) {
    string account_jid = account_str;
    string room_jid = room_str;
    string? p = password == null || password == "" ? null : password;
    Idle.add(() => {
        try {
            var account = enabled_account_by_jid(account_jid);
            if (account == null) {
                emit(@"{\"type\":\"muc_invite_failed\",\"account\":\"$(esc(account_jid))\",\"room\":\"$(esc(room_jid))\",\"message\":\"The invited account is unavailable\"}");
                return Source.REMOVE;
            }
            var jid = new Xmpp.Jid(room_jid).bare_jid;
            var entity_info = app.stream_interactor.get_module(Dino.EntityInfo.IDENTITY);
            entity_info.get_identities.begin(account, jid, (_, res) => {
                var identities = entity_info.get_identities.end(res);
                if (identities == null || identities.size == 0) {
                    emit(@"{\"type\":\"muc_invite_failed\",\"account\":\"$(esc(account_jid))\",\"room\":\"$(esc(jid.to_string()))\",\"message\":\"The invited room is unavailable\"}");
                    return;
                }
                do_join_muc(account, jid, null, p, true);
            });
        } catch (Error e) {
            emit(@"{\"type\":\"muc_invite_failed\",\"account\":\"$(esc(account_jid))\",\"room\":\"$(esc(room_jid))\",\"message\":\"$(esc(e.message))\"}");
        }
        return Source.REMOVE;
    });
}

// Confirmed creation of a room the user opted into (after join_muc found it
// didn't exist). Same join path — the server creates the room and we finalise.
public void create_muc(string jid_str, string? nick) {
    string j = jid_str;
    string? n = nick == null || nick == "" ? null : nick;
    Idle.add(() => {
        try {
            var account = first_enabled_account();
            if (account == null) return Source.REMOVE;
            var jid = new Xmpp.Jid(j).bare_jid;
            do_join_muc(account, jid, n, null, false);
        } catch (Error e) {
            emit(@"{\"type\":\"error\",\"message\":\"$(esc(e.message))\"}");
        }
        return Source.REMOVE;
    });
}

private void do_join_muc(Account account, Xmpp.Jid jid, string? nick, string? password, bool invited) {
    var muc = app.stream_interactor.get_module(Dino.MucManager.IDENTITY);
    muc.join.begin(account, jid, nick, password, false, null, (_, res) => {
        var result = muc.join.end(res);
        if (result == null) {
            if (invited) {
                emit(@"{\"type\":\"muc_invite_failed\",\"account\":\"$(esc(account.bare_jid.to_string()))\",\"room\":\"$(esc(jid.to_string()))\",\"message\":\"Could not join while disconnected\"}");
            } else {
                emit("{\"type\":\"error\",\"message\":\"Could not join: not connected\"}");
            }
        } else if (result.nick == null || (invited && result.newly_created)) {
            if (invited) {
                emit(@"{\"type\":\"muc_invite_failed\",\"account\":\"$(esc(account.bare_jid.to_string()))\",\"room\":\"$(esc(jid.to_string()))\",\"message\":\"Could not join the invited room\"}");
            } else {
                emit(@"{\"type\":\"error\",\"message\":\"Could not join $(esc(jid.to_string()))\"}");
            }
        } else if (result.newly_created) {
            // The room didn't exist, so the server created it locked
            // (XEP-0045 §10.1): nobody — not even us — can send until the owner
            // submits a config form, and it's not persistent until then either.
            // Finalise it so the room is actually usable and lasting.
            finalize_created_muc(account, jid);
        } else {
            push_conversations();
            if (invited) {
                var conversation = app.stream_interactor.get_module(Dino.ConversationManager.IDENTITY)
                    .get_conversation(jid, account, Conversation.Type.GROUPCHAT);
                if (conversation == null) {
                    emit(@"{\"type\":\"muc_invite_failed\",\"account\":\"$(esc(account.bare_jid.to_string()))\",\"room\":\"$(esc(jid.to_string()))\",\"message\":\"The joined room could not be opened\"}");
                    return;
                }
                emit(@"{\"type\":\"muc_invite_joined\",\"account\":\"$(esc(account.bare_jid.to_string()))\",\"room\":\"$(esc(jid.to_string()))\",\"conversation\":$(conversation.id)}");
            }
            // Settle the Room Details view after a (re)join.
            refresh_room_after_join(account, jid);
        }
    });
}

// Unlock and persist a room we just created by joining a non-existent JID.
// Submitting the owner config form unlocks the room; flipping the persistent
// flag on means it survives after everyone leaves (so a second person joining
// the same JID enters OUR room instead of creating their own).
private void finalize_created_muc(Account account, Xmpp.Jid jid) {
    var muc = app.stream_interactor.get_module(Dino.MucManager.IDENTITY);
    muc.get_config_form.begin(account, jid, (_, res) => {
        var form = muc.get_config_form.end(res);
        if (form == null) {
            // No config form (server auto-unlocked); the room is already usable.
            push_conversations();
            return;
        }
        foreach (var field in form.fields) {
            if (field.var == "muc#roomconfig_persistentroom") {
                field.set_value_string("1");
            }
        }
        muc.set_config_form.begin(account, jid, form, (_, res2) => {
            muc.set_config_form.end(res2);
            push_conversations();
        });
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
        if (c != null) emit_occupants(c);
        return Source.REMOVE;
    });
}

private static void emit_occupants(Conversation c) {
    var muc = app.stream_interactor.get_module(Dino.MucManager.IDENTITY);
    var occupants = muc.get_occupants(c.counterpart, c.account);
    Xmpp.Jid? own = muc.get_own_jid(c.counterpart, c.account);
    var b = new StringBuilder();
    b.append_printf("{\"type\":\"occupants\",\"conversation\":%d,\"list\":[", c.id);
    bool first = true;
    if (occupants != null) {
        foreach (Xmpp.Jid occupant in occupants) {
            if (occupant.resourcepart == null) continue;
            if (!first) b.append_c(',');
            first = false;
            bool is_self = own != null && own.equals(occupant);
            // Real bare jid is known only in non-anonymous rooms; "" otherwise.
            Xmpp.Jid? real = muc.get_real_jid(occupant, c.account);
            // Push the occupant's avatar (keyed by their full room jid) so
            // the list can show it.
            push_avatar(c.account, occupant);
            b.append("{\"nick\":\"%s\",\"self\":%s,\"jid\":\"%s\",\"real_jid\":\"%s\",\"affiliation\":\"%s\",\"role\":\"%s\"}".printf(
                esc(occupant.resourcepart), is_self ? "true" : "false",
                esc(occupant.to_string()),
                esc(real != null ? real.bare_jid.to_string() : ""),
                affiliation_name(muc.get_affiliation(c.counterpart, occupant, c.account)),
                role_name(muc.get_role(occupant, c.account))));
        }
    }
    b.append("]}");
    emit(b.str);
}

// Coalesce presence bursts (a join can arrive as several stanzas) into one
// occupant re-push per room, ~350ms after the last change.
private static Gee.HashMap<string, uint>? occ_refresh_timers = null;
private static void schedule_occupants_refresh(Account account, Xmpp.Jid room_bare) {
    Conversation? c = app.stream_interactor.get_module(Dino.ConversationManager.IDENTITY)
        .get_conversation(room_bare, account, Conversation.Type.GROUPCHAT);
    if (c == null) return;
    if (occ_refresh_timers == null) occ_refresh_timers = new Gee.HashMap<string, uint>();
    string key = room_bare.to_string();
    if (occ_refresh_timers.has_key(key)) Source.remove(occ_refresh_timers[key]);
    int cid = c.id;
    occ_refresh_timers[key] = Timeout.add(350, () => {
        occ_refresh_timers.unset(key);
        Conversation? cc = conversation_by_id(cid);
        if (cc != null) emit_occupants(cc);
        return Source.REMOVE;
    });
}

private static string affiliation_name(Xmpp.Xep.Muc.Affiliation? a) {
    switch (a) {
        case Xmpp.Xep.Muc.Affiliation.OWNER: return "owner";
        case Xmpp.Xep.Muc.Affiliation.ADMIN: return "admin";
        case Xmpp.Xep.Muc.Affiliation.MEMBER: return "member";
        case Xmpp.Xep.Muc.Affiliation.OUTCAST: return "outcast";
        default: return "none";
    }
}

private static string role_name(Xmpp.Xep.Muc.Role? r) {
    switch (r) {
        case Xmpp.Xep.Muc.Role.MODERATOR: return "moderator";
        case Xmpp.Xep.Muc.Role.PARTICIPANT: return "participant";
        case Xmpp.Xep.Muc.Role.VISITOR: return "visitor";
        default: return "none";
    }
}

// --- MUC moderation (owner/admin/moderator actions on an occupant) --------
// Each takes the groupchat conversation + the occupant's nick. After the
// server applies the change it broadcasts updated presence; the UI re-requests
// the occupant list to reflect it.
public void muc_kick(int conversation_id, string nick) {
    muc_occupant_action(conversation_id, nick, (muc, c, n) => muc.kick(c.account, c.counterpart, n));
}

// affiliation: "owner" | "admin" | "member" | "outcast" (ban) | "none"
public void muc_set_affiliation(int conversation_id, string nick, string affiliation) {
    string a = affiliation;
    muc_occupant_action(conversation_id, nick, (muc, c, n) => muc.change_affiliation(c.account, c.counterpart, n, a));
}

// role: "moderator" | "participant" | "visitor" | "none"
public void muc_set_role(int conversation_id, string nick, string role) {
    string r = role;
    muc_occupant_action(conversation_id, nick, (muc, c, n) => muc.change_role(c.account, c.counterpart, n, r));
}

private delegate void OccupantAction(Dino.MucManager muc, Conversation c, string nick);
private void muc_occupant_action(int conversation_id, string nick, owned OccupantAction action) {
    int cid = conversation_id;
    string n = nick;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c == null) return Source.REMOVE;
        var muc = app.stream_interactor.get_module(Dino.MucManager.IDENTITY);
        action(muc, c, n);
        return Source.REMOVE;
    });
}

// --- Room-wide settings ---------------------------------------------------

// After a join the room's features, affiliations and occupants settle
// asynchronously over a second or two; re-push room info + occupants a couple
// times so the UI reliably reflects the settled state (rather than depending on
// incidental signals like the disco result or the subject message).
private static void refresh_room_after_join(Account account, Xmpp.Jid jid) {
    Timeout.add(700, () => { reemit_room(account, jid); return Source.REMOVE; });
    Timeout.add(2200, () => { reemit_room(account, jid); return Source.REMOVE; });
}

private static void reemit_room(Account account, Xmpp.Jid jid) {
    var conv = app.stream_interactor.get_module(Dino.ConversationManager.IDENTITY)
        .get_conversation(jid.bare_jid, account, Conversation.Type.GROUPCHAT);
    if (conv != null) { emit_room_info(conv); emit_occupants(conv); }
}

// Re-push every joined group chat (used a few seconds after connect, once the
// auto-rejoins have settled, so Room Details is correct on startup/reconnect).
// Driven from Swift (a reliable main-thread timer) after connect, because the
// libdino auto-rejoin runs on a worker thread where async/timers don't fire
// here. Idle.add lands us on the dino-main loop where joins actually work.
public void rejoin_active_rooms() {
    Idle.add(() => { refresh_all_rooms(); return Source.REMOVE; });
}

private static void refresh_all_rooms() {
    var muc = app.stream_interactor.get_module(Dino.MucManager.IDENTITY);
    var cm = app.stream_interactor.get_module(Dino.ConversationManager.IDENTITY);
    foreach (Conversation c in cm.get_active_conversations()) {
        if (c.type_ != Conversation.Type.GROUPCHAT) continue;
        if (!muc.is_joined(c.counterpart, c.account)) {
            // libdino's bookmark-based auto-rejoin (on_stream_negotiated) doesn't
            // complete on iOS: its async continuation lands on a GLib worker
            // thread that never finishes the join. Drive the join here instead,
            // then re-surface the room once it settles.
            Account a = c.account;
            Xmpp.Jid jid = c.counterpart;
            muc.join.begin(a, jid, c.nickname, null, true, null, (_, res) => {
                muc.join.end(res);
                refresh_room_after_join(a, jid);
            });
        }
        emit_room_info(c);
        emit_occupants(c);
    }
}

private static void emit_room_info(Conversation c) {
    var muc = app.stream_interactor.get_module(Dino.MucManager.IDENTITY);
    Xmpp.Jid? own = muc.get_own_jid(c.counterpart, c.account);
    string subject = muc.get_groupchat_subject(c.counterpart, c.account) ?? "";
    string my_aff = own != null ? affiliation_name(muc.get_affiliation(c.counterpart, own, c.account)) : "none";
    string my_role = own != null ? role_name(muc.get_role(own, c.account)) : "none";
    emit("{\"type\":\"room_info\",\"conversation\":%d,\"subject\":\"%s\",\"is_private\":%s,\"is_moderated\":%s,\"my_affiliation\":\"%s\",\"my_role\":\"%s\"}".printf(
        c.id, esc(subject),
        room_is_private(c) ? "true" : "false",
        muc.is_moderated_room(c.account, c.counterpart) ? "true" : "false",
        my_aff, my_role));
}

public void request_room_info(int conversation_id) {
    int cid = conversation_id;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c != null) emit_room_info(c);
        return Source.REMOVE;
    });
}

public void muc_set_subject(int conversation_id, string subject) {
    int cid = conversation_id;
    string s = subject;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c == null) return Source.REMOVE;
        app.stream_interactor.get_module(Dino.MucManager.IDENTITY).change_subject(c.account, c.counterpart, s);
        return Source.REMOVE;
    });
}

public void muc_invite(int conversation_id, string jid_str) {
    int cid = conversation_id;
    string j = jid_str;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c == null) return Source.REMOVE;
        try {
            bool sent = app.stream_interactor.get_module(Dino.MucManager.IDENTITY).invite(
                c.account, c.counterpart, new Xmpp.Jid(j));
            if (!sent) {
                emit("{\"type\":\"error\",\"message\":\"Could not send invitation while disconnected\"}");
            }
        } catch (Error e) {
            emit(@"{\"type\":\"error\",\"message\":\"$(esc(e.message))\"}");
        }
        return Source.REMOVE;
    });
}

// Owner-only config edits: fetch the room config form, mutate fields, submit.
private static void set_form_field(Xmpp.Xep.DataForms.DataForm form, string var_name, string value) {
    foreach (var field in form.fields) {
        if (field.var == var_name) { field.set_value_string(value); return; }
    }
}

private delegate void ConfigMutator(Xmpp.Xep.DataForms.DataForm form);
private void muc_configure(int conversation_id, owned ConfigMutator mutate) {
    int cid = conversation_id;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c == null) return Source.REMOVE;
        var muc = app.stream_interactor.get_module(Dino.MucManager.IDENTITY);
        muc.get_config_form.begin(c.account, c.counterpart, (_, res) => {
            var form = muc.get_config_form.end(res);
            if (form == null) {
                emit("{\"type\":\"error\",\"message\":\"Couldn't load room settings (owner only).\"}");
                return;
            }
            mutate(form);
            muc.set_config_form.begin(c.account, c.counterpart, form, (_, res2) => {
                muc.set_config_form.end(res2);
                // Don't emit_room_info here: the room's disco features are still
                // cached/stale right after submit, which would revert the
                // optimistic UI. The room_info_updated signal re-emits with
                // fresh data once the server confirms.
            });
        });
        return Source.REMOVE;
    });
}

public void muc_set_name(int conversation_id, string name) {
    string n = name;
    muc_configure(conversation_id, (form) => set_form_field(form, "muc#roomconfig_roomname", n));
}

public void muc_set_private(int conversation_id, bool private_room) {
    bool p = private_room;
    // Making the room private locks it to the current group, and OMEMO encrypts
    // to the member list — so grant membership to everyone present first
    // (queued before the config IQ, so they're members before members-only
    // applies and aren't dropped). Otherwise an open room's non-member
    // participants can't be encrypted to.
    if (p) grant_membership_to_occupants(conversation_id);
    muc_configure(conversation_id, (form) => {
        set_form_field(form, "muc#roomconfig_membersonly", p ? "1" : "0");
        // Non-anonymous when private so members see real jids (needed for OMEMO).
        set_form_field(form, "muc#roomconfig_whois", p ? "anyone" : "moderators");
    });
}

private void grant_membership_to_occupants(int conversation_id) {
    int cid = conversation_id;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c == null) return Source.REMOVE;
        var muc = app.stream_interactor.get_module(Dino.MucManager.IDENTITY);
        var occupants = muc.get_occupants(c.counterpart, c.account);
        Xmpp.Jid? own = muc.get_own_jid(c.counterpart, c.account);
        if (occupants != null) {
            foreach (Xmpp.Jid occ in occupants) {
                if (occ.resourcepart == null) continue;
                if (own != null && own.equals(occ)) continue;
                var aff = muc.get_affiliation(c.counterpart, occ, c.account);
                // Promote only plain participants; leave existing staff/members.
                if (aff == null || aff == Xmpp.Xep.Muc.Affiliation.NONE) {
                    muc.change_affiliation(c.account, c.counterpart, occ.resourcepart, "member");
                }
            }
        }
        return Source.REMOVE;
    });
}

public void muc_set_moderated(int conversation_id, bool moderated) {
    bool m = moderated;
    muc_configure(conversation_id, (form) => set_form_field(form, "muc#roomconfig_moderatedroom", m ? "1" : "0"));
}

// Open a direct chat with a MUC occupant. In a non-anonymous room we know
// their real jid, so start a normal 1:1; otherwise fall back to a private
// message routed through the room (GROUPCHAT_PM to room@conf/nick).
public void start_occupant_dm(int conversation_id, string nick) {
    int cid = conversation_id;
    string n = nick;
    Idle.add(() => {
        Conversation? c = conversation_by_id(cid);
        if (c == null) return Source.REMOVE;
        try {
            var muc = app.stream_interactor.get_module(Dino.MucManager.IDENTITY);
            Xmpp.Jid occupant = c.counterpart.with_resource(n);
            Xmpp.Jid? real = muc.get_real_jid(occupant, c.account);
            var cm = app.stream_interactor.get_module(Dino.ConversationManager.IDENTITY);
            Conversation conv = real != null
                ? cm.create_conversation(real.bare_jid, c.account, Conversation.Type.CHAT)
                : cm.create_conversation(occupant, c.account, Conversation.Type.GROUPCHAT_PM);
            cm.start_conversation(conv);
            push_conversations();
            emit("{\"type\":\"open_conversation\",\"id\":%d}".printf(conv.id));
        } catch (Error e) {
            emit(@"{\"type\":\"error\",\"message\":\"$(esc(e.message))\"}");
        }
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
                remove_temp_staging_path(p);
                return;
            }
            fm.send_file.begin(File.new_for_path(p), c, (_, send_res) => {
                string? send_error = fm.send_file.end(send_res);
                if (send_error != null) {
                    emit("{\"type\":\"error\",\"message\":\"%s\"}".printf(esc((!)send_error)));
                }
                remove_temp_staging_path(p);
            });
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
