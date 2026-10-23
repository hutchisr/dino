using Gee;
using Xmpp;
using Xmpp.Xep;

namespace Xmpp.Xep.JingleFileTransfer {

private const string NS_URI = "urn:xmpp:jingle:apps:file-transfer:5";

public class Module : Jingle.ContentType, XmppStreamModule {

    public signal void file_incoming(XmppStream stream, FileTransfer file_transfer);

    public static Xmpp.ModuleIdentity<Module> IDENTITY = new Xmpp.ModuleIdentity<Module>(NS_URI, "0234_jingle_file_transfer");
    public SessionInfoType session_info_type = new SessionInfoType();

    public override void attach(XmppStream stream) {
        stream.get_module(ServiceDiscovery.Module.IDENTITY).add_feature(stream, NS_URI);
        stream.get_module(Jingle.Module.IDENTITY).register_content_type(this);
        stream.get_module(Jingle.Module.IDENTITY).register_session_info_type(session_info_type);
    }
    public override void detach(XmppStream stream) {
        stream.get_module(ServiceDiscovery.Module.IDENTITY).remove_feature(stream, NS_URI);
    }

    public string ns_uri { get { return NS_URI; } }
    public Jingle.TransportType required_transport_type { get { return Jingle.TransportType.STREAMING; } }
    public uint8 required_components { get { return 1; } }

    public Jingle.ContentParameters parse_content_parameters(StanzaNode description) throws Jingle.IqError {
        return Parameters.parse(this, description);
    }

    public Jingle.ContentParameters create_content_parameters(Object object) throws Jingle.IqError {
        assert_not_reached();
    }

    public async bool is_available(XmppStream stream, Jid full_jid) {
        bool? has_feature = yield stream.get_module(ServiceDiscovery.Module.IDENTITY).has_entity_feature(stream, full_jid, NS_URI);
        if (has_feature == null || !(!)has_feature) {
            return false;
        }
        return yield stream.get_module(Jingle.Module.IDENTITY).is_available(stream, required_transport_type, required_components, full_jid);
    }

    public async void offer_file_stream(XmppStream stream, Jid receiver_full_jid, InputStream input_stream, string basename, int64 size, string? precondition_name = null, Object? precondition_options = null) throws Jingle.Error {
        StanzaNode file_node;
        StanzaNode description = new StanzaNode.build("description", NS_URI)
            .add_self_xmlns()
            .put_node(file_node = new StanzaNode.build("file", NS_URI)
                .put_node(new StanzaNode.build("name", NS_URI).put_node(new StanzaNode.text(basename))));
                // TODO(hrxi): Add the mandatory hash field

        if (size < 0) {
            throw new Jingle.Error.GENERAL("File size is unknown");
        }
        file_node.put_node(
            new StanzaNode.build("size", NS_URI)
                .put_node(new StanzaNode.text(size.to_string())));

        Parameters parameters = Parameters.parse(this, description);

        Jingle.Module jingle_module = stream.get_module(Jingle.Module.IDENTITY);

        Jingle.Transport? transport = yield jingle_module.select_transport(stream, required_transport_type, required_components, receiver_full_jid, Set.empty());
        if (transport == null) {
            throw new Jingle.Error.NO_SHARED_PROTOCOLS("No suitable transports");
        }
        Jingle.SecurityPrecondition? precondition = jingle_module.get_security_precondition(precondition_name);
        if (precondition_name != null && precondition == null) {
            throw new Jingle.Error.UNSUPPORTED_SECURITY("No suitable security precondiiton found");
        }
        Jid? my_jid = stream.get_flag(Bind.Flag.IDENTITY).my_jid;
        if (my_jid == null) {
            throw new Jingle.Error.GENERAL("Couldn't determine own JID");
        }
        Jingle.TransportParameters transport_params = transport.create_transport_parameters(stream, required_components, my_jid, receiver_full_jid);
        Jingle.SecurityParameters? security_params = precondition != null ? precondition.create_security_parameters(stream, my_jid, receiver_full_jid, precondition_options) : null;

        Jingle.Content content = new Jingle.Content.initiate_sent("a-file-offer", Jingle.Senders.INITIATOR,
                this, parameters,
                transport, transport_params,
                precondition, security_params,
                my_jid, receiver_full_jid);

        ArrayList<Jingle.Content> contents = new ArrayList<Jingle.Content>();
        contents.add(content);


        Jingle.Session? session = null;
        try {
            session = yield jingle_module.create_session(stream, contents, receiver_full_jid);

            yield wait_for_connection(content);

            // Send the file data
            Jingle.StreamingConnection connection = content.component_connections[1] as Jingle.StreamingConnection;
            if (connection == null) {
                throw new Jingle.Error.GENERAL("Jingle transport connection is unavailable");
            }
            IOStream io_stream = yield connection.stream.wait_async();
            if (content.security_params == null) yield io_stream.input_stream.close_async();
            yield io_stream.output_stream.splice_async(input_stream, OutputStreamSpliceFlags.CLOSE_SOURCE|OutputStreamSpliceFlags.CLOSE_TARGET);
            yield connection.terminate(true);
        } catch (Error e) {
            if (session != null) {
                session.terminate(Jingle.ReasonElement.FAILED_TRANSPORT, e.message, e.message);
            }
            throw new Jingle.Error.GENERAL("Couldn't send file via Jingle: %s", e.message);
        }
    }

    public override string get_ns() { return NS_URI; }
    public override string get_id() { return IDENTITY.id; }
}

private async void wait_for_connection(Jingle.Content content) throws IOError {
    while (content.state != Jingle.Content.State.ACCEPTED && content.session.state != Jingle.Session.State.ENDED) {
        bool resuming = false;
        ulong content_id = content.notify["state"].connect(() => {
            if (!resuming) {
                resuming = true;
                Idle.add(wait_for_connection.callback);
            }
        });
        ulong session_id = content.session.notify["state"].connect(() => {
            if (!resuming) {
                resuming = true;
                Idle.add(wait_for_connection.callback);
            }
        });
        yield;
        content.disconnect(content_id);
        content.session.disconnect(session_id);
    }
    if (content.session.state == Jingle.Session.State.ENDED) {
        throw new IOError.FAILED("Jingle session ended before the file transfer connected");
    }
}

public class SessionInfoType : Jingle.SessionInfoNs, Object {

    public string ns_uri { get { return NS_URI; } }

    public void handle_content_session_info(XmppStream stream, Jingle.Session session, StanzaNode info, Iq.Stanza iq) throws Jingle.IqError {
        switch (info.name) {
            case "received":
                break;
            case "checksum":
                // TODO(hrxi): handle hash
                break;
            default:
                throw new Jingle.IqError.UNSUPPORTED_INFO(@"unsupported file transfer info $(info.name)");
        }
    }

}

public class Parameters : Jingle.ContentParameters, Object {

    Module parent;
    string? media_type;
    public string? name { get; private set; }
    public int64 size { get; private set; }
    public StanzaNode original_description { get; private set; }

    public Parameters(Module parent, StanzaNode original_description, string? media_type, string? name, int64 size) {
        this.parent = parent;
        this.original_description = original_description;
        this.media_type = media_type;
        this.name = name;
        this.size = size;
    }

    public static Parameters parse(Module parent, StanzaNode description) throws Jingle.IqError {
        Gee.List<StanzaNode> files = description.get_subnodes("file", NS_URI);
        if (files.size != 1) {
            throw new Jingle.IqError.BAD_REQUEST("there needs to be exactly one file node");
        }
        StanzaNode file = files[0];
        StanzaNode? media_type_node = file.get_subnode("media-type", NS_URI);
        StanzaNode? name_node = file.get_subnode("name", NS_URI);
        StanzaNode? size_node = file.get_subnode("size", NS_URI);
        string? media_type = media_type_node != null ? media_type_node.get_string_content() : null;
        string? name = name_node != null ? name_node.get_string_content() : null;
        string? size_raw = size_node != null ? size_node.get_string_content() : null;
        // TODO(hrxi): For some reason, the ?:-expression does not work due to a type error.
        //int64? size = size_raw != null ? int64.parse(size_raw) : null; // TODO(hrxi): this has no error handling
        if (size_raw == null) {
            // Jingle file transfers (XEP-0234) theoretically SHOULD send a
            // file size, however, we do require it in order to reliably find
            // the end of the file transfer.
            throw new Jingle.IqError.BAD_REQUEST("file offer without file size");
        }
        int64 size = int64.parse(size_raw);
        if (size < 0) {
            throw new Jingle.IqError.BAD_REQUEST("negative file size is invalid");
        }

        return new Parameters(parent, description, media_type, name, size);
    }

    public StanzaNode get_description_node() {
        return original_description;
    }

    public async void handle_proposed_content(XmppStream stream, Jingle.Session session, Jingle.Content content) {
        parent.file_incoming(stream, new FileTransfer(session, content, this));
    }

    public void modify(XmppStream stream, Jingle.Session session, Jingle.Content content, Jingle.Senders senders) { }

    public void accept(XmppStream stream, Jingle.Session session, Jingle.Content content) { }

    public void handle_accept(XmppStream stream, Jingle.Session session, Jingle.Content content, StanzaNode description_node) { }

    public void terminate(bool we_terminated, string? reason_name, string? reason_text) { }
}

// Bound plaintext to the offered size; encrypted streams must also reach EOF
// so the converter verifies its trailing authentication tag.
private class FileTransferInputStream : InputStream {

    public signal void closed();

    InputStream inner;
    int64 remaining_size;
    bool verify_eof;

    public FileTransferInputStream(InputStream inner, int64 max_size, bool verify_eof) {
        this.inner = inner;
        this.remaining_size = max_size;
        this.verify_eof = verify_eof;
    }

    private ssize_t update_remaining(ssize_t read) {
        this.remaining_size -= read;
        return read;
    }

    public override ssize_t read(uint8[] buffer_, Cancellable? cancellable = null) throws IOError {
        unowned uint8[] buffer = buffer_;
        if (buffer.length == 0) return 0;
        if (remaining_size <= 0) {
            if (verify_eof && inner.read(buffer[0:1], cancellable) != 0) {
                throw new IOError.INVALID_DATA("Jingle file exceeds its advertised size");
            }
            return 0;
        }
        if (buffer.length > remaining_size) {
            buffer = buffer[0:remaining_size];
        }
        return update_remaining(inner.read(buffer, cancellable));
    }

    public override async ssize_t read_async(uint8[]? buffer_, int io_priority = GLib.Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        unowned uint8[] buffer = buffer_;
        if (buffer.length == 0) return 0;
        if (remaining_size <= 0) {
            if (verify_eof && (yield inner.read_async(buffer[0:1], io_priority, cancellable)) != 0) {
                throw new IOError.INVALID_DATA("Jingle file exceeds its advertised size");
            }
            return 0;
        }
        if (buffer.length > remaining_size) {
            buffer = buffer[0:remaining_size];
        }
        return update_remaining(yield inner.read_async(buffer, io_priority, cancellable));
    }

    public override bool close(Cancellable? cancellable = null) throws IOError {
        bool result = inner.close(cancellable);
        closed();
        return result;
    }

    public override async bool close_async(int io_priority = GLib.Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        bool result = yield inner.close_async(io_priority, cancellable);
        closed();
        return result;
    }
}

public class FileTransfer : Object {
    Jingle.Session session;
    Jingle.Content content;
    Parameters parameters;

    public Jid peer { get { return session.peer_full_jid; } }
    public string? file_name { get { return parameters.name; } }
    public int64 size { get { return parameters.size; } }
    public Jingle.SecurityParameters? security { get { return session.security; } }

    public InputStream? stream { get; private set; }

    public FileTransfer(Jingle.Session session, Jingle.Content content, Parameters parameters) {
        this.session = session;
        this.content = content;
        this.parameters = parameters;
    }

    public async void accept(XmppStream stream) throws IOError {
        content.accept();
        yield wait_for_connection(content);

        Jingle.ComponentConnection[] connections = content.component_connections.values.to_array();
        if (connections.length == 0) {
            throw new IOError.FAILED("Jingle transport connection is unavailable");
        }
        Jingle.StreamingConnection? connection = connections[0] as Jingle.StreamingConnection;
        if (connection == null) {
            throw new IOError.FAILED("Jingle transport is not stream-based");
        }
        try {
            IOStream io_stream = yield connection.stream.wait_async();
            FileTransferInputStream ft_stream = new FileTransferInputStream(io_stream.input_stream, size, content.security_params != null);
            if (content.security_params == null) yield io_stream.output_stream.close_async();
            ft_stream.closed.connect(() => {
                session.terminate(Jingle.ReasonElement.SUCCESS, null, null);
            });
            this.stream = ft_stream;
        } catch (FutureError.EXCEPTION e) {
            throw new IOError.FAILED(
                "Error accepting Jingle file-transfer: %s".printf(connection.stream.exception.message));
        } catch (FutureError e) {
            throw new IOError.FAILED(
                "FutureError accepting Jingle file-transfer: %s".printf(e.message));
        }
    }

    public void reject(XmppStream stream) {
        content.reject();
    }
}

}
