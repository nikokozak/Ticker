import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
import './styles/index.css';
import './types/bridge'; // Initialize bridge

interface RootErrorBoundaryState {
  error: Error | null;
  componentStack: string;
}

// Without a boundary, any uncaught render/effect error unmounts the whole
// tree and leaves a silent white window. Render the error instead.
class RootErrorBoundary extends React.Component<React.PropsWithChildren, RootErrorBoundaryState> {
  state: RootErrorBoundaryState = { error: null, componentStack: '' };

  static getDerivedStateFromError(error: Error): Partial<RootErrorBoundaryState> {
    return { error };
  }

  componentDidCatch(error: Error, info: React.ErrorInfo): void {
    // eslint-disable-next-line no-console
    console.error('[RootErrorBoundary]', error, info.componentStack);
    this.setState({ componentStack: info.componentStack ?? '' });
  }

  render(): React.ReactNode {
    if (!this.state.error) return this.props.children;
    return (
      <div style={{ padding: '2rem', fontFamily: 'ui-monospace, monospace', fontSize: 12, color: '#a4502e', userSelect: 'text' }}>
        <h1 style={{ fontSize: 14 }}>Ticker hit an unexpected error</h1>
        <pre style={{ whiteSpace: 'pre-wrap' }}>{String(this.state.error?.stack ?? this.state.error)}</pre>
        <pre style={{ whiteSpace: 'pre-wrap', opacity: 0.7 }}>{this.state.componentStack}</pre>
        <button type="button" onClick={() => window.location.reload()}>Reload</button>
      </div>
    );
  }
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <RootErrorBoundary>
      <App />
    </RootErrorBoundary>
  </React.StrictMode>,
);
