import { useState } from 'react';
import { Page } from '../components/Page';
import { IntegrationPanel } from '../components/IntegrationPanel';
import { WinwinConfirmationForm } from '../components/WinwinConfirmationForm';
import { MobCashLoginCheck } from '../components/MobCashLoginCheck';

type Tab = 'evc_plus' | 'mobcash_winwin';

export function PaymentIntegrations() {
  const [tab, setTab] = useState<Tab>('evc_plus');
  const [mobcashRefreshKey, setMobcashRefreshKey] = useState(0);

  return (
    <Page title="Payment Integrations" subtitle="Manager-account credentials and connection status for EVC Plus and MobCash / WinWin">
      <div className="note-banner">
        MobCash/WinWin provides no public API, SDK, or partner integration -- confirmed by direct research, not
        assumed. The only real interface is a manager-role login on MobCash Business Web (businessweb-mobi.com),
        normally operated by hand. Anything below labeled "unofficial automation" is Badal Exchange's own
        backend-driven browser automation of that real portal -- not a certified MobCash integration, and not
        something MobCash provides or endorses. "Test connection" honestly reports whether credentials are on file,
        rather than faking a success.
      </div>

      <div className="tabs">
        <button className={`tab ${tab === 'evc_plus' ? 'active' : ''}`} onClick={() => setTab('evc_plus')}>
          EVC Plus
        </button>
        <button className={`tab ${tab === 'mobcash_winwin' ? 'active' : ''}`} onClick={() => setTab('mobcash_winwin')}>
          MobCash Manager
        </button>
      </div>

      {tab === 'evc_plus' && <IntegrationPanel provider="evc_plus" label="EVC Plus" />}
      {tab === 'mobcash_winwin' && (
        <>
          <IntegrationPanel key={mobcashRefreshKey} provider="mobcash_winwin" label="MobCash Manager" />
          <MobCashLoginCheck onSaved={() => setMobcashRefreshKey((k) => k + 1)} />
          <WinwinConfirmationForm />
        </>
      )}
    </Page>
  );
}
