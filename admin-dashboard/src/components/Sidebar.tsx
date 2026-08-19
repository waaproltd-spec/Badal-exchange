import { NavLink } from 'react-router-dom';
import { useAuth } from '../auth/AuthContext';
import {
  IconDashboard,
  IconUsers,
  IconAgent,
  IconWallet,
  IconDown,
  IconUp,
  IconOrders,
  IconTransactions,
  IconPlug,
  IconRate,
  IconFee,
  IconReport,
  IconAudit,
  IconSettings,
  IconLogout,
} from './icons';

const NAV_ITEMS = [
  { to: '/', label: 'Dashboard', icon: IconDashboard, end: true },
  { to: '/customers', label: 'Customers', icon: IconUsers },
  { to: '/agents', label: 'Agents', icon: IconAgent },
  { to: '/wallets', label: 'Wallets', icon: IconWallet },
  { to: '/deposits', label: 'Deposits', icon: IconDown },
  { to: '/withdrawals', label: 'Withdrawals', icon: IconUp },
  { to: '/orders', label: 'Orders', icon: IconOrders },
  { to: '/transactions', label: 'Transactions', icon: IconTransactions },
  { to: '/payment-integrations', label: 'Payment Integrations', icon: IconPlug },
  { to: '/exchange-rates', label: 'Exchange Rates', icon: IconRate },
  { to: '/fees', label: 'Fees', icon: IconFee },
  { to: '/reports', label: 'Reports', icon: IconReport },
  { to: '/audit-logs', label: 'Audit Logs', icon: IconAudit },
  { to: '/settings', label: 'Settings', icon: IconSettings },
];

function initials(name: string | undefined) {
  if (!name) return 'A';
  const parts = name.trim().split(/\s+/);
  return parts
    .slice(0, 2)
    .map((p) => p[0]?.toUpperCase())
    .join('');
}

export function Sidebar() {
  const { user, logout } = useAuth();

  return (
    <aside className="sidebar">
      <div className="sidebar-brand">
        <div className="sidebar-brand-mark">BX</div>
        <div className="sidebar-brand-text">
          <span className="sidebar-brand-name">Badal Exchange</span>
          <span className="sidebar-brand-sub">Admin Dashboard</span>
        </div>
      </div>

      <nav className="sidebar-nav">
        {NAV_ITEMS.map(({ to, label, icon: Icon, end }) => (
          <NavLink key={to} to={to} end={end} className={({ isActive }) => `sidebar-link${isActive ? ' active' : ''}`}>
            <span className="sidebar-link-icon">
              <Icon />
            </span>
            {label}
          </NavLink>
        ))}
      </nav>

      <div className="sidebar-footer">
        <div className="sidebar-user">
          <div className="sidebar-user-avatar">{initials(user?.name)}</div>
          <div style={{ minWidth: 0 }}>
            <div className="sidebar-user-name">{user?.name ?? 'Admin'}</div>
            <div className="sidebar-user-role">{user?.role ?? 'admin'}</div>
          </div>
        </div>
        <button className="sidebar-logout" onClick={logout}>
          <span className="row" style={{ gap: 6 }}>
            <IconLogout width={14} height={14} /> Sign out
          </span>
        </button>
      </div>
    </aside>
  );
}
