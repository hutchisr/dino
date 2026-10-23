namespace Xmpp.Test {

class JingleFileTransferTest : Gee.TestCase {
    public JingleFileTransferTest() {
        base("JingleFileTransfer");
        add_async_test("ibb_payload", (cb) => { transfer.begin(10003, false, false, cb); });
        add_async_test("ibb_empty", (cb) => { transfer.begin(0, false, false, cb); });
        add_async_test("socks5_fallback", (cb) => { transfer.begin(10003, true, false, cb); });
        add_async_test("encrypted_fallback", (cb) => { transfer.begin(10003, true, true, cb); });
        add_async_test("encrypted_empty", (cb) => { transfer.begin(0, false, true, cb); });
        add_async_test("encrypted_bad_tag", (cb) => { transfer.begin(0, false, true, cb, 1); });
        add_async_test("encrypted_truncated_tag", (cb) => { transfer.begin(10003, false, true, cb, 2); });
    }

    private async void receive(JingleFileTransferStream receiver, Xep.JingleFileTransfer.FileTransfer file, uint8[] expected, Gee.Future<bool> sent) throws Error {
        yield file.accept(receiver);
        // Force the final data and close IQs to arrive before draining the queue.
        yield sent.wait_async();
        fail_if_not_eq_int((int) file.size, expected.length);
        uint8[] buffer = new uint8[733];
        int offset = 0;
        ssize_t count;
        while ((count = yield file.stream.read_async(buffer)) > 0) {
            fail_if(offset + count > expected.length);
            for (int i = 0; i < count; i++) {
                fail_if_not_eq_int(buffer[i], expected[offset++]);
            }
        }
        fail_if_not_eq_int(offset, expected.length);
        yield file.stream.close_async();
    }

    private async void transfer(int size, bool fallback, bool encrypted, Gee.TestFinishedCallback cb, int damage = 0) {
        try {
            var sender = new JingleFileTransferStream("sender@example.org/device");
            var receiver = new JingleFileTransferStream("receiver@example.org/device");
            sender.peer = receiver;
            receiver.peer = sender;
            sender.damage = damage;
            sender.payload_size = size;
            if (fallback) {
                sender.add_module(new Xep.Socks5Bytestreams.Module());
                receiver.add_module(new Xep.Socks5Bytestreams.Module());
                sender.add_module(new Xep.JingleSocks5Bytestreams.Module());
                receiver.add_module(new Xep.JingleSocks5Bytestreams.Module());
            }
            if (encrypted) {
                sender.enable_encryption();
                receiver.enable_encryption();
            }
            uint8[] payload = new uint8[size];
            for (int i = 0; i < size; i++) payload[i] = (uint8) (i % 251);
            var received = new Gee.Promise<bool>();
            var sent = new Gee.Promise<bool>();
            receiver.get_module(Xep.JingleFileTransfer.Module.IDENTITY).file_incoming.connect((stream, file) => {
                receive.begin(receiver, file, payload, sent.future, (_, result) => {
                    try {
                        receive.end(result);
                        received.set_value(true);
                    } catch (Error e) {
                        received.set_exception(e);
                    }
                });
            });
            yield sender.get_module(Xep.JingleFileTransfer.Module.IDENTITY).offer_file_stream(
                sender, receiver.jid, new MemoryInputStream.from_bytes(new Bytes(payload)), "payload.bin", size,
                encrypted ? Xep.Jet.NS_URI : null,
                encrypted ? new Xep.Jet.Options("test:known-key", "test:aes-gcm") : null);
            sent.set_value(true);
            try {
                fail_if_not(yield received.future.wait_async());
                fail_if(damage != 0, "A damaged authentication tag was accepted");
            } catch (Gee.FutureError e) {
                if (damage == 0) throw received.future.exception;
                fail_if_not(sender.damaged);
                fail_if_not(received.future.exception is IOError);
            }
            sender.detach_modules();
            receiver.detach_modules();
        } catch (Error e) {
            fail_if_reached(e.message);
        }
        cb();
    }
}

// Only the XMPP wire is local: discovery, negotiation, IBB and file I/O are real.
private class JingleFileTransferStream : XmppStream, Xep.ServiceDiscovery.CapsCache {
    public Jid jid;
    public weak JingleFileTransferStream peer;
    public int damage = 0;
    public int payload_size = 0;
    public bool damaged = false;
    private int sent_bytes = 0;

    public JingleFileTransferStream(string address) throws InvalidJidError {
        base(new Jid("example.org"));
        jid = new Jid(address);
        add_flag(new Bind.Flag() { my_jid = jid, finished = true });
        negotiation_complete = true;
        add_module(new Iq.Module());
        add_module(new Xep.ServiceDiscovery.Module.with_identity("client", "pc") { cache = this });
        add_module(new Xep.Jingle.Module());
        add_module(new Xep.InBandBytestreams.Module());
        add_module(new Xep.JingleInBandBytestreams.Module());
        add_module(new Xep.JingleFileTransfer.Module());
    }

    public void enable_encryption() {
        var jet = new Xep.Jet.Module();
        add_module(jet);
        jet.register_cipher(new TransferCipher());
        jet.register_envelop_encoding(new TransferEnvelope());
    }

    public async bool has_entity_feature(Jid jid, string feature) {
        var info = yield get_module(Xep.ServiceDiscovery.Module.IDENTITY).request_info(this, jid);
        return info != null && info.features.contains(feature);
    }

    public async Gee.Set<Xep.ServiceDiscovery.Identity> get_entity_identities(Jid jid) {
        var info = yield get_module(Xep.ServiceDiscovery.Module.IDENTITY).request_info(this, jid);
        return info.identities;
    }

    public override async void connect() throws IOError { }
    public override async void disconnect() throws IOError { }
    public override async void setup() throws IOError { }
    public override async StanzaNode read() throws IOError {
        throw new IOError.NOT_SUPPORTED("Stanzas are delivered through received_iq_stanza");
    }
    public override void write(StanzaNode node, int io_priority = Priority.DEFAULT) {
        write_async.begin(node, io_priority);
    }
    public override async void write_async(StanzaNode node, int io_priority = Priority.DEFAULT, Cancellable? cancellable = null) throws IOError {
        node.put_attribute("from", jid.to_string());
        var data = node.get_subnode("data", "http://jabber.org/protocol/ibb");
        if (data != null && damage != 0) {
            uint8[] bytes = Base64.decode(data.get_string_content());
            sent_bytes += bytes.length;
            if (!damaged && sent_bytes > payload_size) {
                if (damage == 1) bytes[bytes.length - 1] ^= 1;
                else bytes = bytes[0:bytes.length - 1];
                data.sub_nodes.clear();
                data.put_node(new StanzaNode.text(Base64.encode(bytes)));
                damaged = true;
            }
        }
        JingleFileTransferStream target = peer;
        Idle.add(() => {
            target.received_iq_stanza(target, node);
            return Source.REMOVE;
        });
    }
}

// Fixed test keys exercise the real AES-GCM converters, not OMEMO key exchange.
private class TransferCipher : Object, Xep.Jet.Cipher {
    public string get_cipher_uri() { return "test:aes-gcm"; }
    public Xep.Jet.TransportSecret generate_random_secret() {
        return new Xep.Jet.TransportSecret(new uint8[16], new uint8[12]);
    }
    public InputStream wrap_input_stream(InputStream input, Xep.Jet.TransportSecret secret) {
        var cipher = new Crypto.SymmetricCipher("AES-GCM");
        cipher.set_key(secret.transport_key);
        cipher.set_iv(secret.initialization_vector);
        return new ConverterInputStream(input, new Crypto.SymmetricCipherDecrypter((owned) cipher, 16));
    }
    public OutputStream wrap_output_stream(OutputStream output, Xep.Jet.TransportSecret secret) {
        var cipher = new Crypto.SymmetricCipher("AES-GCM");
        cipher.set_key(secret.transport_key);
        cipher.set_iv(secret.initialization_vector);
        return new ConverterOutputStream(output, new Crypto.SymmetricCipherEncrypter((owned) cipher, 16));
    }
}

private class TransferEnvelope : Object, Xep.Jet.EnvelopEncoding {
    public string get_type_uri() { return "test:known-key"; }
    public Xep.Jet.TransportSecret decode_envolop(XmppStream stream, Jid local, Jid peer, StanzaNode security) throws Xep.Jingle.IqError {
        return new Xep.Jet.TransportSecret(new uint8[16], new uint8[12]);
    }
    public void encode_envelop(XmppStream stream, Jid local, Jid peer, Xep.Jet.SecurityParameters parameters, StanzaNode security) { }
}

}
