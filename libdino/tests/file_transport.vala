using Dino.Entities;

namespace Dino.Test {

class FileTransportTest : Gee.TestCase {
    private Database db;
    private FileManager manager;
    private Conversation conversation;
    private PreviewSender http;
    private PreviewSender jingle;
    private string directory;
    private File file;

    public FileTransportTest() {
        base("FileTransport");
        add_test("priority_size_and_availability", test_priority_size_and_availability);
        add_test("encryption_required_and_native_fallback", test_encryption_required_and_native_fallback);
        add_test("external_encryption_preserves_priority", test_external_encryption_preserves_priority);
        add_test("preview_is_read_only_and_reports_file_errors", test_preview_is_read_only_and_reports_file_errors);
    }

    public override void set_up() {
        db = new Database(":memory:");
        var si = new StreamInteractor(db);
        FileManager.start(si, db);
        manager = si.get_module(FileManager.IDENTITY);
        // Register in reverse priority order to exercise FileManager's ordering.
        jingle = new PreviewSender(1, 75, int64.MAX);
        http = new PreviewSender(0, 100, 5);
        manager.add_sender(jingle);
        manager.add_sender(http);
        try {
            var account = new Account(new Xmpp.Jid("me@example.org"), "");
            conversation = new Conversation(new Xmpp.Jid("peer@example.org"), account, Conversation.Type.CHAT);
            conversation.encryption = Encryption.NONE;
            directory = DirUtils.make_tmp("dino-file-transport-XXXXXX");
            file = File.new_for_path(Path.build_filename(directory, "attachment"));
            FileUtils.set_contents(file.get_path(), "data");
        } catch (Error e) {
            error("Could not prepare transport test: %s", e.message);
        }
    }

    public override void tear_down() {
        FileUtils.remove(file.get_path());
        DirUtils.remove(directory);
    }

    private int preview(File? selected = null) throws Error {
        var loop = new MainLoop();
        Error? failure = null;
        int sender = -1;
        bool completed = false;
        uint timeout = Timeout.add_seconds(5, () => {
            fail_if_reached("Transport preview did not complete");
            loop.quit();
            return Source.CONTINUE;
        });
        manager.preview_file_transport.begin(selected ?? file, conversation, (_, result) => {
            try {
                sender = manager.preview_file_transport.end(result);
            } catch (Error e) {
                failure = e;
            }
            completed = true;
            loop.quit();
        });
        if (!completed) loop.run();
        Source.remove(timeout);
        if (failure != null) throw failure;
        return sender;
    }

    private void test_priority_size_and_availability() {
        try {
            fail_if_not_eq_int(preview(), 0);
            // HTTP uses a strict upper limit: equality must fall back, not upload.
            http.limit = 4;
            fail_if_not_eq_int(preview(), 1);
            http.limit = 5;
            http.available = false;
            fail_if_not_eq_int(preview(), 1);
            jingle.available = false;
            try {
                preview();
                fail_if_reached("Unavailable transports were selected");
            } catch (FileSendError.UPLOAD_FAILED e) { }
        } catch (Error e) {
            fail_if_reached(e.message);
        }
    }

    private void test_encryption_required_and_native_fallback() {
        conversation.encryption = Encryption.OMEMO;
        try {
            try {
                preview();
                fail_if_reached("Encrypted attachment accepted without an encryptor");
            } catch (FileSendError.UPLOAD_FAILED e) { }
            jingle.native_encryption = true;
            fail_if_not_eq_int(preview(), 1);
        } catch (Error e) {
            fail_if_reached(e.message);
        }
    }

    private void test_external_encryption_preserves_priority() {
        conversation.encryption = Encryption.OMEMO;
        jingle.native_encryption = true;
        manager.add_file_encryptor(new PreviewEncryptor());
        try {
            // External encryption makes the higher-priority HTTP sender eligible.
            fail_if_not_eq_int(preview(), 0);
            http.available = false;
            jingle.native_encryption = false;
            try {
                preview();
                fail_if_reached("HTTP-only encryption was selected for Jingle");
            } catch (FileSendError.UPLOAD_FAILED e) { }
            jingle.native_encryption = true;
            fail_if_not_eq_int(preview(), 1);
        } catch (Error e) {
            fail_if_reached(e.message);
        }
    }

    private void test_preview_is_read_only_and_reports_file_errors() {
        manager.received_file.connect(() => fail_if_reached("Preview published a transfer"));
        try {
            preview();
            fail_if_not(db.file_transfer.select().count() == 0, "Preview persisted a transfer");
            string contents;
            FileUtils.get_contents(file.get_path(), out contents);
            fail_if_not_eq_str(contents, "data");
            try {
                preview(File.new_for_path(Path.build_filename(directory, "missing")));
                fail_if_reached("Missing attachment was accepted");
            } catch (IOError.NOT_FOUND e) { }
            try {
                preview(File.new_for_path(directory));
                fail_if_reached("Directory was accepted as an attachment");
            } catch (IOError.NOT_SUPPORTED e) { }
        } catch (Error e) {
            fail_if_reached(e.message);
        }
    }
}

// Capability fixtures: all actual preparation/transmission is forbidden in preview.
private class PreviewSender : Object, FileSender {
    public bool available = true;
    public bool native_encryption = false;
    public int64 limit;
    private int sender_id;
    private float priority;

    public PreviewSender(int sender_id, float priority, int64 limit) {
        this.sender_id = sender_id;
        this.priority = priority;
        this.limit = limit;
    }

    public async bool is_upload_available(Conversation conversation) { return available; }
    public async long get_file_size_limit(Conversation conversation) { return (long) limit; }
    public async bool can_send(Conversation conversation, FileTransfer transfer) {
        return available && transfer.size < limit;
    }
    public async bool can_encrypt(Conversation conversation, FileTransfer transfer) { return native_encryption; }
    public int get_id() { return sender_id; }
    public float get_priority() { return priority; }
    public async FileSendData? prepare_send_file(Conversation conversation, FileTransfer transfer, FileMeta meta) throws FileSendError {
        fail_if_reached("Preview prepared a transfer");
        throw new FileSendError.UPLOAD_FAILED("Preview must not prepare a transfer");
    }
    public async void send_file(Conversation conversation, FileTransfer transfer, FileSendData data, FileMeta meta) throws FileSendError {
        fail_if_reached("Preview transmitted a file");
    }
}

private class PreviewEncryptor : Object, FileEncryptor {
    public bool can_encrypt_file(Conversation conversation, FileTransfer transfer) {
        return transfer.encryption == Encryption.OMEMO;
    }
    public FileMeta encrypt_file(Conversation conversation, FileTransfer transfer) throws FileSendError {
        fail_if_reached("Preview encrypted a file");
        throw new FileSendError.ENCRYPTION_FAILED("Preview must not encrypt a file");
    }
    public FileSendData? preprocess_send_file(Conversation conversation, FileTransfer transfer, FileSendData data, FileMeta meta) throws FileSendError {
        fail_if_reached("Preview preprocessed a transfer");
        throw new FileSendError.ENCRYPTION_FAILED("Preview must not preprocess a transfer");
    }
}

}
