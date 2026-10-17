namespace Xmpp.Test {

class JingleFileTransferTest : Gee.TestCase {
    public JingleFileTransferTest() {
        base("JingleFileTransfer");
        add_async_test("zero_size_offer_has_size", (cb) => {
            test_zero_size_offer_has_size.begin(cb);
        });
    }

    private async void test_zero_size_offer_has_size(Gee.TestFinishedCallback cb) {
        try {
            var stream = new JingleFileTransferStream();
            var module = new Xep.JingleFileTransfer.Module();
            yield module.offer_file_stream(
                stream,
                new Jid("peer@example.org/device"),
                new MemoryInputStream(),
                "empty.bin",
                0);
            fail_if_reached("A transport-less stream accepted an offer");
        } catch (Xep.Jingle.Error.NO_SHARED_PROTOCOLS e) {
            // Reaching transport selection proves the zero-byte description parsed.
        } catch (Error e) {
            fail_if_reached(e.message);
        }
        cb();
    }
}

private class JingleFileTransferStream : XmppStream {
    public JingleFileTransferStream() throws InvalidJidError {
        base(new Jid("example.org"));
        add_module(new Xep.Jingle.Module());
    }

    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { }
    public override async void setup() throws IOError { }
    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_SUPPORTED("No network in this test");
    }
    public override void write(StanzaNode node, int io_priority = Priority.DEFAULT) { }
    public override async void write_async(
        StanzaNode node,
        int io_priority = Priority.DEFAULT,
        Cancellable? cancellable = null
    ) throws IOError { }
}

}
