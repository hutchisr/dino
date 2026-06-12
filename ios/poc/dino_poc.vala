// Proof-of-concept bridge between Dino's XMPP core (xmpp-vala) and the iOS
// SwiftUI shell. Exposes a minimal C API (see generated dino_poc.h): start a
// GLib main loop on a background thread, log in, receive roster + messages,
// send a message. Events are reported to Swift as tab-separated lines through
// a single callback to keep the C surface trivial.

namespace DinoPoc {

    public delegate void LineCb(string line);

    [CCode (cname = "dino_poc_register_tls_backend")]
    extern void register_tls_backend();

    private static MainLoop? main_loop = null;
    private static Xmpp.XmppStream? the_stream = null;

    public void init() {
        if (main_loop != null) return;
        register_tls_backend();
        main_loop = new MainLoop(null, false);
        new Thread<bool>("glib-main", () => {
            main_loop.run();
            return true;
        });
    }

    public void login(string jid_str, string password, owned LineCb cb) {
        string j = jid_str;
        string p = password;
        Idle.add(() => {
            login_async.begin(j, p, (line) => cb(line));
            return Source.REMOVE;
        });
    }

    private async void login_async(string jid_str, string password, owned LineCb cb) {
        try {
            var jid = new Xmpp.Jid(jid_str);
            cb(@"STATUS\tResolving $(jid.domainpart) and connecting…");

            var modules = new Gee.ArrayList<Xmpp.XmppStreamModule>();
            modules.add(new Xmpp.Iq.Module());
            modules.add(new Xmpp.Sasl.Module(jid.bare_jid.to_string(), password));
            modules.add(new Xmpp.Bind.Module("dino.ios"));
            modules.add(new Xmpp.Session.Module());
            modules.add(new Xmpp.Presence.Module());
            modules.add(new Xmpp.Roster.Module());
            modules.add(new Xmpp.MessageModule());

            var result = yield Xmpp.establish_stream(jid.bare_jid, modules, null, (peer_cert, errors) => {
                cb("STATUS\tWARNING: TLS certificate could not be verified, accepting anyway (PoC)");
                return true;
            });

            if (result.stream == null) {
                if (result.io_error != null) {
                    cb(@"ERROR\tConnection failed: $(result.io_error.message)");
                } else {
                    cb("ERROR\tConnection failed (TLS)");
                }
                return;
            }

            var stream = result.stream;
            the_stream = stream;

            stream.get_module(Xmpp.Sasl.Module.IDENTITY).received_auth_failure.connect(() => {
                cb("ERROR\tAuthentication failed (wrong JID or password?)");
            });
            stream.stream_negotiated.connect(() => {
                cb(@"CONNECTED\t$(jid.bare_jid.to_string())");
            });
            stream.get_module(Xmpp.Roster.Module.IDENTITY).received_roster.connect((s, roster, iq) => {
                cb(@"STATUS\tRoster received: $(roster.size) contacts");
                foreach (Xmpp.Roster.Item item in roster) {
                    cb(@"CONTACT\t$(item.jid.to_string())\t$(item.name ?? "")");
                }
            });
            stream.get_module(Xmpp.MessageModule.IDENTITY).received_message.connect((s, msg) => {
                if (msg.body == null) return;
                cb(@"MSG\t$(msg.from.to_string())\t$(msg.body)");
            });

            yield stream.loop();
            the_stream = null;
            cb("STATUS\tDisconnected");
        } catch (Error e) {
            the_stream = null;
            cb(@"ERROR\t$(e.message)");
        }
    }

    public void send_message(string to, string body, owned LineCb cb) {
        string t = to;
        string b = body;
        Idle.add(() => {
            var stream = the_stream;
            if (stream == null) {
                cb("ERROR\tNot connected");
                return Source.REMOVE;
            }
            try {
                var msg = new Xmpp.MessageStanza();
                msg.to = new Xmpp.Jid(t);
                msg.body = b;
                msg.type_ = Xmpp.MessageStanza.TYPE_CHAT;
                stream.get_module(Xmpp.MessageModule.IDENTITY).send_message.begin(stream, msg, () => {
                    cb(@"SENT\t$(t)\t$(b)");
                });
            } catch (Error e) {
                cb(@"ERROR\t$(e.message)");
            }
            return Source.REMOVE;
        });
    }
}
