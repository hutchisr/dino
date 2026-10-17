using Dino.Entities;

namespace Dino.Test {

class FileTransportTest : Gee.TestCase {
    private Database db;
    private StreamInteractor stream_interactor;
    private FileManager manager;
    private Account account;
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
        add_test("outgoing_state_is_persisted", test_outgoing_state_is_persisted);
        add_test("stale_transfer_state_is_reconciled", test_stale_transfer_state_is_reconciled);
        add_test("sent_sync_uses_conversation_counterpart", test_sent_sync_uses_conversation_counterpart);
        add_test("short_download_is_rejected", test_short_download_is_rejected);
    }

    public override void set_up() {
        db = new Database(":memory:");
        stream_interactor = new StreamInteractor(db);
        MessageProcessor.start(stream_interactor, db);
        Calls.start(stream_interactor, db);
        ConversationManager.start(stream_interactor, db);
        FileManager.start(stream_interactor, db);
        FileTransferStorage.start(stream_interactor, db);
        manager = stream_interactor.get_module(FileManager.IDENTITY);
        // Register in reverse priority order to exercise FileManager's ordering.
        jingle = new PreviewSender(1, 75, int64.MAX);
        http = new PreviewSender(0, 100, 5);
        manager.add_sender(jingle);
        manager.add_sender(http);
        try {
            account = new Account(new Xmpp.Jid("me@example.org"), "");
            account.persist(db);
            conversation = new Conversation(new Xmpp.Jid("peer@example.org"), account, Conversation.Type.CHAT);
            conversation.encryption = Encryption.NONE;
            conversation.persist(db);
            stream_interactor.module_manager.initialize(account);
            stream_interactor.account_added(account);
            conversation = stream_interactor.get_module(ConversationManager.IDENTITY)
                .get_conversation(conversation.counterpart, account);
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
    private string? send() {
        var loop = new MainLoop();
        string? failure = null;
        manager.send_file.begin(file, conversation, (_, result) => {
            failure = manager.send_file.end(result);
            loop.quit();
        });
        loop.run();
        return failure;
    }

    private void download(FileTransfer transfer) {
        var loop = new MainLoop();
        manager.download_file.begin(transfer, (_, result) => {
            manager.download_file.end(result);
            loop.quit();
        });
        loop.run();
    }

    private void test_outgoing_state_is_persisted() {
        manager.add_sender(new CompletingSender());
        FileTransfer? published = null;
        FileTransfer.State persisted_at_publish = FileTransfer.State.COMPLETE;
        manager.received_file.connect((transfer, _) => {
            published = transfer;
            var row = db.file_transfer.select()
                .with(db.file_transfer.id, "=", transfer.id)
                .row().inner;
            persisted_at_publish = (FileTransfer.State) row[db.file_transfer.state];
        });

        fail_if(send() != null, "The fixture sender should complete");
        fail_if(published == null, "Outgoing transfer was not published");
        fail_if_not_eq_int(persisted_at_publish, FileTransfer.State.IN_PROGRESS);
        fail_if_not_eq_int(published.state, FileTransfer.State.COMPLETE);
        var row = db.file_transfer.select()
            .with(db.file_transfer.id, "=", published.id)
            .row().inner;
        fail_if_not_eq_int((FileTransfer.State) row[db.file_transfer.state], FileTransfer.State.COMPLETE);
        FileUtils.remove(published.get_file().get_path());
    }

    private void test_stale_transfer_state_is_reconciled() {
        var transfer = new FileTransfer() {
            account = account,
            counterpart = conversation.counterpart,
            ourpart = account.full_jid,
            direction = FileTransfer.DIRECTION_SENT,
            time = new DateTime.now_utc(),
            local_time = new DateTime.now_utc(),
            file_name = "stale.bin",
            size = 4,
            state = FileTransfer.State.IN_PROGRESS,
            provider = 0,
            info = ""
        };
        transfer.persist(db);
        var row = db.file_transfer.select()
            .with(db.file_transfer.id, "=", transfer.id)
            .row().inner;
        try {
            var restored = new FileTransfer.from_row(db, row, FileManager.get_storage_dir());
            fail_if_not_eq_int(restored.state, FileTransfer.State.FAILED);
            row = db.file_transfer.select()
                .with(db.file_transfer.id, "=", transfer.id)
                .row().inner;
            fail_if_not_eq_int((FileTransfer.State) row[db.file_transfer.state], FileTransfer.State.FAILED);
        } catch (Error e) {
            fail_if_reached(e.message);
        }
    }

    private void test_sent_sync_uses_conversation_counterpart() {
        var provider = new ShortFileProvider();
        var meta = new FileMeta() { file_name = "sent.bin", size = 3 };
        var transfer = manager.create_file_transfer_from_provider_incoming(
            provider, "1", account.full_jid, new DateTime.now_utc(),
            new DateTime.now_utc(), conversation, new FileReceiveData(), meta);
        fail_if_not(transfer.direction == FileTransfer.DIRECTION_SENT);
        fail_if_not_eq_str(transfer.counterpart.to_string(), conversation.counterpart.to_string());
    }

    private void test_short_download_is_rejected() {
        var provider = new ShortFileProvider();
        manager.add_provider(provider);
        var meta = new FileMeta() { file_name = "short.bin", size = 10 };
        var transfer = manager.create_file_transfer_from_provider_incoming(
            provider, "short", conversation.counterpart, new DateTime.now_utc(),
            new DateTime.now_utc(), conversation, new FileReceiveData(), meta);
        stream_interactor.get_module(FileTransferStorage.IDENTITY).add_file(transfer);
        GLib.Test.expect_message("libdino", LogLevelFlags.LEVEL_WARNING, "*7 bytes remaining*");
        download(transfer);
        GLib.Test.assert_expected_messages();
        fail_if_not_eq_int(transfer.state, FileTransfer.State.NOT_STARTED);
        fail_if_not(transfer.path == null, "Partial download retained a path");
    }
}

private class ShortFileProvider : Object, FileProvider {
    public Encryption get_encryption(FileTransfer transfer, FileReceiveData data, FileMeta meta) {
        return Encryption.NONE;
    }
    public FileMeta get_file_meta(FileTransfer transfer) throws FileReceiveError {
        return new FileMeta() {
            file_name = transfer.file_name,
            size = transfer.size,
            mime_type = "application/octet-stream"
        };
    }
    public FileReceiveData? get_file_receive_data(FileTransfer transfer) {
        return new FileReceiveData();
    }
    public async FileMeta get_meta_info(FileTransfer transfer, FileReceiveData data, FileMeta meta) throws FileReceiveError {
        return meta;
    }
    public async InputStream download(FileTransfer transfer, FileReceiveData data, FileMeta meta) throws IOError {
        return new LimitInputStream(new MemoryInputStream.from_data("abc".data), meta.size);
    }
    public int get_id() { return 0; }
}

private class CompletingSender : Object, FileSender {
    public async bool is_upload_available(Conversation conversation) { return true; }
    public async long get_file_size_limit(Conversation conversation) { return (long) int64.MAX; }
    public async bool can_send(Conversation conversation, FileTransfer transfer) { return true; }
    public async bool can_encrypt(Conversation conversation, FileTransfer transfer) { return true; }
    public async FileSendData? prepare_send_file(
        Conversation conversation,
        FileTransfer transfer,
        FileMeta meta
    ) throws FileSendError {
        return new FileSendData();
    }
    public async void send_file(
        Conversation conversation,
        FileTransfer transfer,
        FileSendData data,
        FileMeta meta
    ) throws FileSendError {}
    public int get_id() { return 9; }
    public float get_priority() { return 200; }
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
