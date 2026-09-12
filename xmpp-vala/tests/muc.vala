namespace Xmpp.Test {

class MucTest : Gee.TestCase {
    private const string ADMIN_NS = "http://jabber.org/protocol/muc#admin";

    public MucTest() {
        base("Muc");
        add_async_test("affiliation_cache", (cb) => { test_affiliation_cache.begin(cb); });
        add_async_test("nickname_target", (cb) => { test_nickname_target.begin(cb); });
    }

    private async void test_affiliation_cache(Gee.TestFinishedCallback cb) {
        try {
            var room = new Jid("room@conference.example.org");
            var member = new Jid("member@example.org/device");
            var stream = new AffiliationStream(room);
            var muc = new Xep.Muc.Module();
            var flag = stream.get_flag(Xep.Muc.Flag.IDENTITY);
            var expected = Xep.Muc.Affiliation.NONE;
            stream.request_written.connect((request) => {
                var item = request.get_deep_subnode(ADMIN_NS + ":query", ADMIN_NS + ":item");
                fail_if_not_eq_str(request.get_attribute("to"), room.to_string());
                fail_if_not_eq_str(item.get_attribute("jid"), member.bare_jid.to_string());
                fail_if_not_eq_str(item.get_attribute("nick"), null);
                fail_if_not_eq_int(flag.get_affiliation(room, member.bare_jid), expected,
                    "cache must not change before the server response");
            });

            fail_if_not(yield muc.change_affiliation(stream, room, member, null, "member"));
            expected = Xep.Muc.Affiliation.MEMBER;
            fail_if_not_eq_int(flag.get_affiliation(room, member.bare_jid), expected);
            fail_if_not(flag.get_offline_members(room).contains(member.bare_jid));

            stream.reject = true;
            fail_if(yield muc.change_affiliation(stream, room, member, null, "admin"));
            fail_if_not_eq_int(flag.get_affiliation(room, member.bare_jid), expected,
                "rejected promotion must preserve membership");
            fail_if(yield muc.change_affiliation(stream, room, member, null, "none"));
            fail_if_not(flag.get_offline_members(room).contains(member.bare_jid),
                "rejected removal must preserve membership");

            stream.reject = false;
            fail_if_not(yield muc.change_affiliation(stream, room, member, null, "admin"));
            expected = Xep.Muc.Affiliation.ADMIN;
            fail_if_not_eq_int(flag.get_affiliation(room, member.bare_jid), expected);

            fail_if_not(yield muc.change_affiliation(stream, room, member, null, "none"));
            expected = Xep.Muc.Affiliation.NONE;
            fail_if_not_eq_int(flag.get_affiliation(room, member.bare_jid), expected);
            fail_if(flag.get_offline_members(room).contains(member.bare_jid));

            fail_if_not(yield muc.change_affiliation(stream, room, member, null, "outcast"));
            expected = Xep.Muc.Affiliation.OUTCAST;
            fail_if_not_eq_int(flag.get_affiliation(room, member.bare_jid), expected);
        } catch (Error e) {
            fail_if_reached(e.message);
        }
        cb();
    }

    private async void test_nickname_target(Gee.TestFinishedCallback cb) {
        try {
            var room = new Jid("room@conference.example.org");
            var stream = new AffiliationStream(room);
            stream.request_written.connect((request) => {
                var item = request.get_deep_subnode(ADMIN_NS + ":query", ADMIN_NS + ":item");
                fail_if_not_eq_str(item.get_attribute("nick"), "Anonymous Member");
                fail_if_not_eq_str(item.get_attribute("jid"), null);
            });
            fail_if_not(yield new Xep.Muc.Module().change_affiliation(stream, room, null, "Anonymous Member", "member"));
            fail_if_not_eq_int(stream.get_flag(Xep.Muc.Flag.IDENTITY).get_offline_members(room).size, 0,
                "nickname-only success must not invent a real member JID");
        } catch (Error e) {
            fail_if_reached(e.message);
        }
        cb();
    }
}

private class AffiliationStream : XmppStream {
    public bool reject = false;
    public signal void request_written(StanzaNode request);
    private Jid sender;

    public AffiliationStream(Jid room) throws InvalidJidError {
        base(room);
        sender = new Jid("viewer@example.org/device");
        add_flag(new Xep.Muc.Flag());
        add_module(new Iq.Module());
        attach_negotation_modules();
    }

    public override async void write_async(StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        request_written(node);
        var request = new Iq.Stanza.from_stanza(node, sender);
        Iq.Stanza response = reject
            ? new Iq.Stanza.error(request, new ErrorStanza.service_unavailable())
            : new Iq.Stanza.result(request);
        response.from = request.to;
        Idle.add(() => {
            received_iq_stanza(this, response.stanza);
            return Source.REMOVE;
        });
    }

    public override void write(StanzaNode node, int io_priority = Priority.DEFAULT) {
        write_async.begin(node, io_priority);
    }

    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { }
    public override async void setup() throws IOError { }
    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_SUPPORTED("Responses are delivered through received_iq_stanza");
    }
}

}
