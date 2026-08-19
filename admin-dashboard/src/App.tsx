import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { AuthProvider } from './auth/AuthContext';
import { ProtectedRoute } from './components/ProtectedRoute';
import { Layout } from './components/Layout';
import { Login } from './pages/Login';
import { Dashboard } from './pages/Dashboard';
import { Customers } from './pages/Customers';
import { CustomerDetail } from './pages/CustomerDetail';
import { Agents } from './pages/Agents';
import { AgentDetail } from './pages/AgentDetail';
import { Wallets } from './pages/Wallets';
import { WalletLedger } from './pages/WalletLedger';
import { Deposits } from './pages/Deposits';
import { Withdrawals } from './pages/Withdrawals';
import { Orders } from './pages/Orders';
import { OrderDetail } from './pages/OrderDetail';
import { Transactions } from './pages/Transactions';
import { PaymentIntegrations } from './pages/PaymentIntegrations';
import { ExchangeRates } from './pages/ExchangeRates';
import { Fees } from './pages/Fees';
import { Reports } from './pages/Reports';
import { AuditLogs } from './pages/AuditLogs';
import { Settings } from './pages/Settings';

function App() {
  return (
    <BrowserRouter>
      <AuthProvider>
        <Routes>
          <Route path="/login" element={<Login />} />

          <Route element={<ProtectedRoute />}>
            <Route element={<Layout />}>
              <Route path="/" element={<Dashboard />} />
              <Route path="/customers" element={<Customers />} />
              <Route path="/customers/:id" element={<CustomerDetail />} />
              <Route path="/agents" element={<Agents />} />
              <Route path="/agents/:id" element={<AgentDetail />} />
              <Route path="/wallets" element={<Wallets />} />
              <Route path="/wallets/:customerId" element={<WalletLedger />} />
              <Route path="/deposits" element={<Deposits />} />
              <Route path="/withdrawals" element={<Withdrawals />} />
              <Route path="/orders" element={<Orders />} />
              <Route path="/orders/:id" element={<OrderDetail />} />
              <Route path="/transactions" element={<Transactions />} />
              <Route path="/payment-integrations" element={<PaymentIntegrations />} />
              <Route path="/exchange-rates" element={<ExchangeRates />} />
              <Route path="/fees" element={<Fees />} />
              <Route path="/reports" element={<Reports />} />
              <Route path="/audit-logs" element={<AuditLogs />} />
              <Route path="/settings" element={<Settings />} />
            </Route>
          </Route>

          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </AuthProvider>
    </BrowserRouter>
  );
}

export default App;
