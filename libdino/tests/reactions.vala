using Dino.Entities;

namespace Dino.Test {

class ReactionsTest : Gee.TestCase {
    public ReactionsTest() {
        base("Reactions");
        add_test("unaddressable_file_reports_error", test_unaddressable_file_reports_error);
    }

    private void test_unaddressable_file_reports_error() {
        var db = new Database(":memory:");
        var si = new StreamInteractor(db);
        MessageProcessor.start(si, db);
        FileManager.start(si, db);
        Calls.start(si, db);
        ContentItemStore.start(si, db);
        Reactions.start(si, db);
        try {
            var account = new Account(new Xmpp.Jid("me@example.org"), "");
            account.persist(db);
            var conversation = new Conversation(new Xmpp.Jid("peer@example.org"), account, Conversation.Type.CHAT);
            var transfer = new FileTransfer() {
                account = account,
                counterpart = conversation.counterpart,
                ourpart = account.bare_jid,
                time = new DateTime.now_utc(),
                provider = 1,
                info = Xmpp.random_uuid(),
                file_name = "image.webp"
            };
            var item = new FileItem(transfer, conversation, 1);
            var reactions = si.get_module(Reactions.IDENTITY);
            bool signalled = false;
            reactions.reaction_added.connect(() => { signalled = true; });
            reactions.reaction_removed.connect(() => { signalled = true; });
            fail_if_not_error_code(() => reactions.add_reaction(conversation, item, "👍"), IOError.FAILED);
            fail_if_not_error_code(() => reactions.remove_reaction(conversation, item, "👍"), IOError.FAILED);
            fail_if(signalled, "An unsupported reaction must not signal success");
            fail_if_not_eq_int(reactions.get_item_reactions(conversation, item).size, 0);
        } catch (Error e) {
            fail_if_reached(e.message);
        }
    }
}

}
