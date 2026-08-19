import { useState } from 'react';
import { Page } from '../components/Page';
import { IntegrationPanel } from '../components/IntegrationPanel';
import { WinwinConfirmationForm } from '../components/WinwinConfirmationForm';

type Tab = 'evc_plus' | 'mobcash_winwin';

export function PaymentIntegrations() {
  const [tab, setTab] = useState<Tab>('evc_plus');

  return (
    <Page title="Payment Integrations" subtitle="Manager-account credentials and connection status for EVC Plus and MobCash / WinWin">
      <div className="note-banner">
        MobCash/WinWin has no public API -- only a manager-role login inside the WinWin mobile app, used by a human to
        manually top up or pay out. Badal Exchange does not automate that login. "Test connection" honestly reports
        whether credentials are on file and whether a verified provider adapter exists (it does not yet), rather than
        faking a success.
      </div>

      <div className="tabs">
        <button className={`tab ${tab === 'evc_plus' ? 'active' : ''}`} onClick={() => setTab('evc_plus')}>
          EVC Plus
        </button>
        <button className={`tab ${tab === 'mobcash_winwin' ? 'active' : ''}`} onClick={() => setTab('mobcash_winwin')}>
          MobCash / WinWin
        </button>
      </div>

      {tab === 'evc_plus' && <IntegrationPanel provider="evc_plus" label="EVC Plus" />}
      {tab === 'mobcash_winwin' && (
        <>
          <IntegrationPanel provider="mobcash_winwin" label="MobCash / WinWin" />
          <WinwinConfirmationForm />
        </>
      )}
    </Page>
  );
}
