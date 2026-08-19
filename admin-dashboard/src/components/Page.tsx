import type { ReactNode } from 'react';

export function Page({
  title,
  subtitle,
  actions,
  children,
}: {
  title: string;
  subtitle?: string;
  actions?: ReactNode;
  children: ReactNode;
}) {
  return (
    <>
      <div className="topbar">
        <div>
          <div className="topbar-title">{title}</div>
          {subtitle && <div className="topbar-subtitle">{subtitle}</div>}
        </div>
        {actions && <div className="row">{actions}</div>}
      </div>
      <div className="page-content">
        <div className="stack">{children}</div>
      </div>
    </>
  );
}
