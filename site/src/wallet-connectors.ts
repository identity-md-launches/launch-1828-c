// This module is imported only after Connect opens. SDK setup must stay off the public read path.
import { coinbaseWallet, walletConnect } from "wagmi/connectors";
import { wagmiConfig, walletConnectProjectId, SITE_NAME, SITE_DESCRIPTION, SITE_URL, SITE_ICON_URL } from "./config";

export function registerWallets() {
  const factories = [
    coinbaseWallet({ appName: SITE_NAME }),
    ...(walletConnectProjectId ? [walletConnect({ projectId: walletConnectProjectId, showQrModal: true,
      metadata: { name: SITE_NAME, description: SITE_DESCRIPTION, url: SITE_URL, icons: [SITE_ICON_URL] } })] : []),
  ];
  // wagmi 2's connector store preserves discovered EIP-6963 providers and connected accounts.
  const store = wagmiConfig._internal.connectors;
  const added = factories.map((factory) => store.setup(factory));
  store.setState((current) => [...current, ...added]);
}
