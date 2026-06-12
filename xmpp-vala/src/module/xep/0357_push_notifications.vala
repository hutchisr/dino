namespace Xmpp.Xep.PushNotifications {

private const string NS_URI = "urn:xmpp:push:0";

public class Module : XmppStreamModule {
    public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0357_push_notifications");

    public async bool is_supported(XmppStream stream, Jid server_jid) {
        return yield stream.get_module(ServiceDiscovery.Module.IDENTITY).has_entity_feature(stream, server_jid, NS_URI);
    }

    public async bool enable(XmppStream stream, Jid push_jid, string node) {
        StanzaNode enable_node = new StanzaNode.build("enable", NS_URI).add_self_xmlns()
                .put_attribute("jid", push_jid.to_string())
                .put_attribute("node", node);
        Iq.Stanza iq = new Iq.Stanza.set(enable_node);
        try {
            Iq.Stanza result = yield stream.get_module(Iq.Module.IDENTITY).send_iq_async(stream, iq);
            return !result.is_error();
        } catch (IOError e) {
            return false;
        }
    }

    public async bool disable(XmppStream stream, Jid push_jid, string? node = null) {
        StanzaNode disable_node = new StanzaNode.build("disable", NS_URI).add_self_xmlns()
                .put_attribute("jid", push_jid.to_string());
        if (node != null) disable_node.put_attribute("node", node);
        Iq.Stanza iq = new Iq.Stanza.set(disable_node);
        try {
            Iq.Stanza result = yield stream.get_module(Iq.Module.IDENTITY).send_iq_async(stream, iq);
            return !result.is_error();
        } catch (IOError e) {
            return false;
        }
    }

    public override void attach(XmppStream stream) { }
    public override void detach(XmppStream stream) { }
    public override string get_ns() { return NS_URI; }
    public override string get_id() { return IDENTITY.id; }
}

}
