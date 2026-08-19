import type { SVGProps } from 'react';

type IconProps = SVGProps<SVGSVGElement>;

const base = {
  width: 17,
  height: 17,
  viewBox: '0 0 24 24',
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 2,
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
};

export const IconDashboard = (p: IconProps) => (
  <svg {...base} {...p}>
    <rect x="3" y="3" width="7" height="9" rx="1.5" />
    <rect x="14" y="3" width="7" height="5" rx="1.5" />
    <rect x="14" y="12" width="7" height="9" rx="1.5" />
    <rect x="3" y="16" width="7" height="5" rx="1.5" />
  </svg>
);

export const IconUsers = (p: IconProps) => (
  <svg {...base} {...p}>
    <circle cx="9" cy="8" r="3.2" />
    <path d="M3 20c0-3.5 2.7-6 6-6s6 2.5 6 6" />
    <circle cx="17.5" cy="8.5" r="2.6" />
    <path d="M15.5 14.3c2.6.4 4.5 2.5 4.5 5.7" />
  </svg>
);

export const IconAgent = (p: IconProps) => (
  <svg {...base} {...p}>
    <rect x="3" y="7" width="18" height="13" rx="2" />
    <path d="M8 7V5a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />
    <path d="M3 12h18" />
  </svg>
);

export const IconWallet = (p: IconProps) => (
  <svg {...base} {...p}>
    <rect x="3" y="6" width="18" height="13" rx="2" />
    <path d="M3 10h18" />
    <circle cx="16" cy="14" r="1.4" fill="currentColor" stroke="none" />
  </svg>
);

export const IconDown = (p: IconProps) => (
  <svg {...base} {...p}>
    <path d="M12 4v13" />
    <path d="M6 12l6 6 6-6" />
    <path d="M5 21h14" />
  </svg>
);

export const IconUp = (p: IconProps) => (
  <svg {...base} {...p}>
    <path d="M12 20V7" />
    <path d="M6 13l6-6 6 6" />
    <path d="M5 21h14" />
  </svg>
);

export const IconOrders = (p: IconProps) => (
  <svg {...base} {...p}>
    <path d="M6 2h9l4 4v16H6z" />
    <path d="M15 2v4h4" />
    <path d="M9 12h6M9 16h6M9 8h2" />
  </svg>
);

export const IconTransactions = (p: IconProps) => (
  <svg {...base} {...p}>
    <path d="M4 7h13l-3-3M20 17H7l3 3" />
  </svg>
);

export const IconPlug = (p: IconProps) => (
  <svg {...base} {...p}>
    <path d="M9 2v5M15 2v5" />
    <path d="M7 7h10v4a5 5 0 0 1-10 0V7z" />
    <path d="M12 16v3M9 22h6" />
  </svg>
);

export const IconRate = (p: IconProps) => (
  <svg {...base} {...p}>
    <path d="M3 17l6-6 4 4 8-8" />
    <path d="M15 6h6v6" />
  </svg>
);

export const IconFee = (p: IconProps) => (
  <svg {...base} {...p}>
    <circle cx="12" cy="12" r="9" />
    <path d="M9 9h.01M15 15h.01M8.5 15.5l7-7" />
  </svg>
);

export const IconReport = (p: IconProps) => (
  <svg {...base} {...p}>
    <path d="M4 19V5a2 2 0 0 1 2-2h8l6 6v10a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2z" />
    <path d="M14 3v6h6" />
    <path d="M8 13h4M8 17h8" />
  </svg>
);

export const IconAudit = (p: IconProps) => (
  <svg {...base} {...p}>
    <path d="M9 3h9a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V7z" />
    <path d="M9 3v4H5" />
    <path d="M9 12h6M9 16h4" />
  </svg>
);

export const IconSettings = (p: IconProps) => (
  <svg {...base} {...p}>
    <circle cx="12" cy="12" r="3" />
    <path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.6V21a2 2 0 1 1-4 0v-.2a1.7 1.7 0 0 0-1-1.5 1.7 1.7 0 0 0-1.9.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.9 1.7 1.7 0 0 0-1.6-1H3a2 2 0 1 1 0-4h.2a1.7 1.7 0 0 0 1.5-1 1.7 1.7 0 0 0-.3-1.9l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.9.3H9a1.7 1.7 0 0 0 1-1.6V3a2 2 0 1 1 4 0v.2a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.9-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.9V9a1.7 1.7 0 0 0 1.6 1H21a2 2 0 1 1 0 4h-.2a1.7 1.7 0 0 0-1.5 1z" />
  </svg>
);

export const IconLogout = (p: IconProps) => (
  <svg {...base} {...p}>
    <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
    <path d="M16 17l5-5-5-5" />
    <path d="M21 12H9" />
  </svg>
);
