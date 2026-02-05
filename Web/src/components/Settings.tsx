import { useState, useEffect } from 'react';
import { bridge } from '../types';
import { isUnifiedEditorEnabled, setUnifiedEditorEnabled } from '../utils/featureFlags';
import { debugError } from '../utils/debug';

type Appearance = 'light' | 'dark' | 'system';
type DefaultModel = 'openai' | 'anthropic';

interface SettingsData {
  hasOpenAIKey: boolean;
  openaiKeyPreview?: string;
  hasAnthropicKey: boolean;
  anthropicKeyPreview?: string;
  hasPerplexityKey: boolean;
  perplexityKeyPreview?: string;
  smartRoutingEnabled: boolean;
  defaultModel: DefaultModel;
  classifierReady?: boolean;
  classifierLoading?: boolean;
  classifierError?: string;
  appearance: Appearance;
  diagnosticsEnabled: boolean;
}

// Proxy auth state (matches Swift ProxyAuthState enum)
type ProxyAuthState =
  | 'unregistered'
  | 'validating'
  | 'active'
  | 'blockedInvalid'
  | 'blockedRevoked'
  | 'blockedBoundElsewhere'
  | 'degradedOffline';

interface Limits {
  reqsPerMin: number | null;
  tokensPerDay: number | null;
  tokensPerMonth: number | null;
}

interface Usage {
  reqsThisMinute: number | null;
  tokensToday: number | null;
  tokensThisMonth: number | null;
  dayResetAt: string | null;
  monthResetAt: string | null;
}

interface ProxyAuthStatus {
  state: ProxyAuthState;
  supportId: string | null;
  deviceId: string;
  limits: Limits | null;
  usage: Usage | null;
}

interface SettingsProps {
  onClose: () => void;
}

export function Settings({ onClose }: SettingsProps) {
  const [settings, setSettings] = useState<SettingsData | null>(null);
  const [openaiKey, setOpenaiKey] = useState('');
  const [anthropicKey, setAnthropicKey] = useState('');
  const [perplexityKey, setPerplexityKey] = useState('');
  const [showKey, setShowKey] = useState(false);
  const [showAnthropicKey, setShowAnthropicKey] = useState(false);
  const [showPerplexityKey, setShowPerplexityKey] = useState(false);
  const [saved, setSaved] = useState(false);
  const [anthropicSaved, setAnthropicSaved] = useState(false);
  const [perplexitySaved, setPerplexitySaved] = useState(false);
  const [useUnifiedEditor, setUseUnifiedEditor] = useState(isUnifiedEditorEnabled());

  // Proxy auth state
  const [proxyAuth, setProxyAuth] = useState<ProxyAuthStatus | null>(null);
  const [deviceKeyInput, setDeviceKeyInput] = useState('');
  const [deviceKeyValidating, setDeviceKeyValidating] = useState(false);
  const [deviceKeyError, setDeviceKeyError] = useState<string | null>(null);

  // Feedback form state (D5)
  const [feedbackType, setFeedbackType] = useState<'bug' | 'feature'>('bug');
  const [feedbackTitle, setFeedbackTitle] = useState('');
  const [feedbackDesc, setFeedbackDesc] = useState('');
  const [feedbackScreenshot, setFeedbackScreenshot] = useState<string | null>(null);
  const [feedbackScreenshotType, setFeedbackScreenshotType] = useState<string>('image/png');
  const [feedbackSubmitting, setFeedbackSubmitting] = useState(false);
  const [feedbackSuccess, setFeedbackSuccess] = useState<string | null>(null);
  const [feedbackError, setFeedbackError] = useState<string | null>(null);

  // Maximum attachment size (10MB per OpenAPI spec)
  const MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024;

  // Load settings on mount
  useEffect(() => {
    const unsubscribe = bridge.onMessage((message) => {
      if (message.type === 'settingsLoaded' && message.payload?.settings) {
        setSettings(message.payload.settings as SettingsData);
      }
    });

    bridge.send({ type: 'loadSettings' });

    return unsubscribe;
  }, []);

  // Load proxy auth status on mount, then refresh from server
  useEffect(() => {
    // First, load cached state immediately (no network call)
    bridge.sendAsync<ProxyAuthStatus>('loadProxyAuth')
      .then(setProxyAuth)
      .catch(() => debugError('Failed to load proxy auth'));

    // Then refresh from server to get fresh usage data
    bridge.sendAsync<ProxyAuthStatus>('refreshProxyAuth')
      .then(setProxyAuth)
      .catch(() => debugError('Failed to refresh proxy auth'));
  }, []);

  // Validate device key
  const handleValidateDeviceKey = async () => {
    if (!deviceKeyInput.trim()) return;

    setDeviceKeyValidating(true);
    setDeviceKeyError(null);

    try {
      const result = await bridge.sendAsync<{
        success: boolean;
        state: ProxyAuthState;
        supportId: string;
        limits: Limits | null;
        usage: Usage | null;
      }>('setProxyDeviceKey', {
        key: deviceKeyInput.trim(),
      });
      setProxyAuth({
        state: result.state,
        supportId: result.supportId,
        deviceId: proxyAuth?.deviceId ?? '',
        limits: result.limits,
        usage: result.usage,
      });
      setDeviceKeyInput('');
    } catch (err) {
      setDeviceKeyError(err instanceof Error ? err.message : 'Validation failed');
    } finally {
      setDeviceKeyValidating(false);
    }
  };

  // Clear device key
  const handleClearDeviceKey = async () => {
    try {
      const result = await bridge.sendAsync<{ success: boolean; state: ProxyAuthState }>('clearProxyDeviceKey');
      setProxyAuth((prev) => (prev ? { ...prev, state: result.state, supportId: null, limits: null, usage: null } : null));
    } catch (err) {
      debugError('Failed to clear device key');
    }
  };

  // Submit feedback (D5)
  const handleSubmitFeedback = async () => {
    if (!feedbackTitle.trim()) return;

    setFeedbackSubmitting(true);
    setFeedbackError(null);
    setFeedbackSuccess(null);

    try {
      const result = await bridge.sendAsync<{
        success: boolean;
        feedbackId?: string;
        error?: string;
      }>('submitFeedback', {
        type: feedbackType,
        title: feedbackTitle.trim(),
        description: feedbackDesc.trim() || undefined,
        screenshot: feedbackScreenshot || undefined,
        screenshotContentType: feedbackScreenshot ? feedbackScreenshotType : undefined,
      });

      if (result.success && result.feedbackId) {
        setFeedbackSuccess(result.feedbackId);
        // Clear form
        setFeedbackTitle('');
        setFeedbackDesc('');
        setFeedbackScreenshot(null);
        setFeedbackScreenshotType('image/png');
      } else {
        setFeedbackError(result.error || 'Failed to submit feedback');
      }
    } catch (err) {
      setFeedbackError(err instanceof Error ? err.message : 'Failed to submit feedback');
    } finally {
      setFeedbackSubmitting(false);
    }
  };

  // Copy support bundle to clipboard (D5)
  const handleCopySupportBundle = async () => {
    try {
      const result = await bridge.sendAsync<{ bundle: Record<string, unknown> }>('getSupportBundle');
      const bundleJson = JSON.stringify(result.bundle, null, 2);
      await navigator.clipboard.writeText(bundleJson);
      // Could show a toast here, but for simplicity just alert
      alert('Support bundle copied to clipboard');
    } catch (err) {
      debugError('Failed to copy support bundle');
      alert('Failed to copy support bundle');
    }
  };

  // Handle image paste/drop for feedback screenshot (D5)
  const handleImagePaste = (e: React.ClipboardEvent) => {
    const items = e.clipboardData.items;
    for (const item of items) {
      if (item.type.startsWith('image/')) {
        const file = item.getAsFile();
        if (file) {
          // Check size limit (10MB)
          if (file.size > MAX_ATTACHMENT_BYTES) {
            setFeedbackError('Screenshot is too large. Maximum size is 10MB.');
            return;
          }
          const contentType = file.type;
          const reader = new FileReader();
          reader.onload = (event) => {
            const dataUrl = event.target?.result as string;
            // Extract base64 part (remove data:image/...;base64, prefix)
            const base64 = dataUrl.split(',')[1];
            setFeedbackScreenshot(base64);
            setFeedbackScreenshotType(contentType);
            setFeedbackError(null);
          };
          reader.readAsDataURL(file);
        }
        break;
      }
    }
  };

  const handleImageDrop = (e: React.DragEvent) => {
    e.preventDefault();
    const file = e.dataTransfer.files[0];
    if (file && file.type.startsWith('image/')) {
      // Check size limit (10MB)
      if (file.size > MAX_ATTACHMENT_BYTES) {
        setFeedbackError('Screenshot is too large. Maximum size is 10MB.');
        return;
      }
      const contentType = file.type;
      const reader = new FileReader();
      reader.onload = (event) => {
        const dataUrl = event.target?.result as string;
        const base64 = dataUrl.split(',')[1];
        setFeedbackScreenshot(base64);
        setFeedbackScreenshotType(contentType);
        setFeedbackError(null);
      };
      reader.readAsDataURL(file);
    }
  };

  const handleDragOver = (e: React.DragEvent) => {
    e.preventDefault();
  };

  const clearScreenshot = () => {
    setFeedbackScreenshot(null);
    setFeedbackScreenshotType('image/png');
  };

  const handleSaveOpenAI = () => {
    bridge.send({
      type: 'saveSettings',
      payload: { openaiAPIKey: openaiKey },
    });
    setSaved(true);
    setTimeout(() => setSaved(false), 2000);
    setOpenaiKey(''); // Clear input after save
    // Reload settings to update preview
    setTimeout(() => bridge.send({ type: 'loadSettings' }), 100);
  };

  const handleSaveAnthropic = () => {
    bridge.send({
      type: 'saveSettings',
      payload: { anthropicAPIKey: anthropicKey },
    });
    setAnthropicSaved(true);
    setTimeout(() => setAnthropicSaved(false), 2000);
    setAnthropicKey(''); // Clear input after save
    setTimeout(() => bridge.send({ type: 'loadSettings' }), 100);
  };

  const handleSavePerplexity = () => {
    bridge.send({
      type: 'saveSettings',
      payload: { perplexityAPIKey: perplexityKey },
    });
    setPerplexitySaved(true);
    setTimeout(() => setPerplexitySaved(false), 2000);
    setPerplexityKey(''); // Clear input after save
    setTimeout(() => bridge.send({ type: 'loadSettings' }), 100);
  };

  const handleDeleteOpenAI = () => {
    bridge.send({
      type: 'saveSettings',
      payload: { openaiAPIKey: '' },
    });
    setTimeout(() => bridge.send({ type: 'loadSettings' }), 100);
  };

  const handleDeleteAnthropic = () => {
    bridge.send({
      type: 'saveSettings',
      payload: { anthropicAPIKey: '' },
    });
    setTimeout(() => bridge.send({ type: 'loadSettings' }), 100);
  };

  const handleDeletePerplexity = () => {
    bridge.send({
      type: 'saveSettings',
      payload: { perplexityAPIKey: '' },
    });
    setTimeout(() => bridge.send({ type: 'loadSettings' }), 100);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Escape') {
      onClose();
    }
  };

  return (
    <div className="settings" onKeyDown={handleKeyDown}>
      <header className="settings-header">
        <h1>Settings</h1>
        <button onClick={onClose} className="settings-close">
          Done
        </button>
      </header>

      <div className="settings-content">
        <section className="settings-section">
          <h2>Device Key</h2>
          <div className="settings-field">
            {proxyAuth?.state === 'active' || proxyAuth?.state === 'degradedOffline' ? (
              <div className="settings-device-key-status">
                <div className="settings-device-key-connected">
                  <span className="settings-device-key-badge">
                    {proxyAuth.state === 'degradedOffline' ? 'Offline' : 'Connected'}
                  </span>
                  <span className="settings-device-key-support-id">
                    Support ID: <code>{proxyAuth.supportId}</code>
                  </span>
                </div>
                <button
                  className="settings-disconnect-btn"
                  onClick={handleClearDeviceKey}
                  type="button"
                >
                  Disconnect
                </button>
                <p className="settings-hint">
                  {proxyAuth.state === 'degradedOffline'
                    ? 'Unable to reach server. Using cached credentials.'
                    : 'Your device is registered with Ticker. AI features are enabled.'}
                </p>
              </div>
            ) : proxyAuth?.state === 'validating' ? (
              <div className="settings-device-key-entry">
                <p className="settings-hint" style={{ marginTop: 0 }}>
                  Validating device key...
                </p>
                <div className="loading-spinner" />
              </div>
            ) : (
              <div className="settings-device-key-entry">
                <p className="settings-hint" style={{ marginTop: 0 }}>
                  Enter your device key to enable AI features.
                </p>
                <div className="settings-key-input">
                  <input
                    type="password"
                    value={deviceKeyInput}
                    onChange={(e) => setDeviceKeyInput(e.target.value)}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter' && deviceKeyInput.trim()) {
                        handleValidateDeviceKey();
                      }
                    }}
                    placeholder="tk_live_..."
                    disabled={deviceKeyValidating}
                    autoComplete="off"
                  />
                  <button
                    className="settings-save-key"
                    onClick={handleValidateDeviceKey}
                    disabled={deviceKeyValidating || !deviceKeyInput.trim()}
                  >
                    {deviceKeyValidating ? 'Validating...' : 'Validate'}
                  </button>
                </div>
                {deviceKeyError && (
                  <p className="settings-error">{deviceKeyError}</p>
                )}
              </div>
            )}
          </div>
        </section>

        {/* Usage section - only visible when connected */}
        {(proxyAuth?.state === 'active' || proxyAuth?.state === 'degradedOffline') &&
          proxyAuth.limits && proxyAuth.usage && (
          <section className="settings-section">
            <h2>Usage</h2>
            <div className="settings-field">
              <UsageDisplay limits={proxyAuth.limits} usage={proxyAuth.usage} />
            </div>
          </section>
        )}

        {/* Privacy section (D6) */}
        <section className="settings-section">
          <h2>Privacy</h2>
          <div className="settings-field">
            <label className="settings-toggle-label">
              <input
                type="checkbox"
                checked={settings?.diagnosticsEnabled ?? true}
                onChange={(e) => {
                  bridge.send({
                    type: 'saveSettings',
                    payload: { diagnosticsEnabled: e.target.checked },
                  });
                }}
              />
              <span>Send diagnostics</span>
            </label>
            <p className="settings-hint">
              When enabled, Ticker sends request IDs and app/OS version with each
              request to help troubleshoot issues. No note content or prompts are
              collected.
            </p>
          </div>
        </section>

        {/* Testing section - only visible when connected (D5) */}
        {(proxyAuth?.state === 'active' || proxyAuth?.state === 'degradedOffline') && (
          <section className="settings-section">
            <h2>Testing</h2>
            <div className="settings-field">
              <p className="settings-hint" style={{ marginTop: 0 }}>
                Help improve Ticker by reporting bugs or suggesting features.
              </p>

              {/* Feedback type selector */}
              <div className="settings-feedback-type">
                <button
                  type="button"
                  className={feedbackType === 'bug' ? 'active' : ''}
                  onClick={() => setFeedbackType('bug')}
                >
                  Report Bug
                </button>
                <button
                  type="button"
                  className={feedbackType === 'feature' ? 'active' : ''}
                  onClick={() => setFeedbackType('feature')}
                >
                  Request Feature
                </button>
              </div>

              {/* Form fields */}
              <input
                type="text"
                className="settings-feedback-title"
                placeholder="Title (required)"
                value={feedbackTitle}
                onChange={(e) => setFeedbackTitle(e.target.value)}
                disabled={feedbackSubmitting}
              />
              <textarea
                className="settings-feedback-desc"
                placeholder="Description (optional)"
                value={feedbackDesc}
                onChange={(e) => setFeedbackDesc(e.target.value)}
                disabled={feedbackSubmitting}
                rows={4}
              />

              {/* Screenshot drop zone */}
              <div
                className="settings-screenshot-drop"
                onDrop={handleImageDrop}
                onDragOver={handleDragOver}
                onPaste={handleImagePaste}
                tabIndex={0}
              >
                {feedbackScreenshot ? (
                  <div className="settings-screenshot-preview">
                    <img
                      src={`data:${feedbackScreenshotType};base64,${feedbackScreenshot}`}
                      alt="Screenshot preview"
                    />
                    <button
                      type="button"
                      onClick={clearScreenshot}
                      className="settings-screenshot-remove"
                    >
                      Remove
                    </button>
                  </div>
                ) : (
                  <span>Drag &amp; drop or paste screenshot (optional)</span>
                )}
              </div>

              {/* Submit button */}
              <button
                type="button"
                className="settings-feedback-submit"
                onClick={handleSubmitFeedback}
                disabled={feedbackSubmitting || !feedbackTitle.trim()}
              >
                {feedbackSubmitting ? 'Submitting...' : 'Submit'}
              </button>

              {/* Success/error messages */}
              {feedbackSuccess && (
                <p className="settings-success">
                  Submitted! Reference: <code>{feedbackSuccess}</code>
                </p>
              )}
              {feedbackError && (
                <p className="settings-error">{feedbackError}</p>
              )}
            </div>

            {/* Support Bundle */}
            <div className="settings-field">
              <label>Support Bundle</label>
              <button
                type="button"
                className="settings-support-bundle-btn"
                onClick={handleCopySupportBundle}
              >
                Copy to Clipboard
              </button>
              <p className="settings-hint">
                Copies diagnostic info (no content or keys) for support requests.
              </p>
            </div>
          </section>
        )}

        <section className="settings-section">
          <h2>Editor</h2>
          <div className="settings-field">
            <label className="settings-toggle-label">
              <input
                type="checkbox"
                checked={useUnifiedEditor}
                onChange={(e) => {
                  const next = e.target.checked;
                  setUseUnifiedEditor(next);
                  setUnifiedEditorEnabled(next);
                }}
              />
              <span>Unified editor (experimental)</span>
            </label>
            <p className="settings-hint">
              Uses a single TipTap editor for the whole stream (cross-cell selection + unified editing).
              URL override still works: <code>?unified=true</code>.
            </p>
          </div>
        </section>

        <section className="settings-section">
          <h2>API Keys</h2>

          <div className="settings-field">
            <label htmlFor="openai-key">OpenAI API Key</label>
            <div className="settings-key-input">
              <input
                id="openai-key"
                type={showKey ? 'text' : 'password'}
                value={openaiKey}
                onChange={(e) => setOpenaiKey(e.target.value)}
                placeholder={settings?.openaiKeyPreview || 'sk-...'}
                autoComplete="off"
              />
              {openaiKey && (
                <button
                  className="settings-toggle-visibility"
                  onClick={() => setShowKey(!showKey)}
                  type="button"
                >
                  {showKey ? 'Hide' : 'Show'}
                </button>
              )}
              <button
                className="settings-save-key"
                onClick={handleSaveOpenAI}
                disabled={!openaiKey}
              >
                {saved ? 'Saved!' : 'Save'}
              </button>
              {settings?.hasOpenAIKey && !openaiKey && (
                <button
                  className="settings-delete-key"
                  onClick={handleDeleteOpenAI}
                  type="button"
                >
                  Delete
                </button>
              )}
            </div>
            <p className="settings-hint">
              {settings?.hasOpenAIKey
                ? 'Key is configured. Enter a new key to replace it.'
                : 'Required for AI features. Get one at platform.openai.com'}
            </p>
          </div>

          <div className="settings-field">
            <label htmlFor="anthropic-key">Anthropic API Key</label>
            <div className="settings-key-input">
              <input
                id="anthropic-key"
                type={showAnthropicKey ? 'text' : 'password'}
                value={anthropicKey}
                onChange={(e) => setAnthropicKey(e.target.value)}
                placeholder={settings?.anthropicKeyPreview || 'sk-ant-...'}
                autoComplete="off"
              />
              {anthropicKey && (
                <button
                  className="settings-toggle-visibility"
                  onClick={() => setShowAnthropicKey(!showAnthropicKey)}
                  type="button"
                >
                  {showAnthropicKey ? 'Hide' : 'Show'}
                </button>
              )}
              <button
                className="settings-save-key"
                onClick={handleSaveAnthropic}
                disabled={!anthropicKey}
              >
                {anthropicSaved ? 'Saved!' : 'Save'}
              </button>
              {settings?.hasAnthropicKey && !anthropicKey && (
                <button
                  className="settings-delete-key"
                  onClick={handleDeleteAnthropic}
                  type="button"
                >
                  Delete
                </button>
              )}
            </div>
            <p className="settings-hint">
              {settings?.hasAnthropicKey
                ? 'Key is configured. Enter a new key to replace it.'
                : 'For Claude models. Get one at console.anthropic.com'}
            </p>
          </div>

          <div className="settings-field">
            <label htmlFor="perplexity-key">Perplexity API Key (Optional)</label>
            <div className="settings-key-input">
              <input
                id="perplexity-key"
                type={showPerplexityKey ? 'text' : 'password'}
                value={perplexityKey}
                onChange={(e) => setPerplexityKey(e.target.value)}
                placeholder={settings?.perplexityKeyPreview || 'pplx-...'}
                autoComplete="off"
              />
              {perplexityKey && (
                <button
                  className="settings-toggle-visibility"
                  onClick={() => setShowPerplexityKey(!showPerplexityKey)}
                  type="button"
                >
                  {showPerplexityKey ? 'Hide' : 'Show'}
                </button>
              )}
              <button
                className="settings-save-key"
                onClick={handleSavePerplexity}
                disabled={!perplexityKey}
              >
                {perplexitySaved ? 'Saved!' : 'Save'}
              </button>
              {settings?.hasPerplexityKey && !perplexityKey && (
                <button
                  className="settings-delete-key"
                  onClick={handleDeletePerplexity}
                  type="button"
                >
                  Delete
                </button>
              )}
            </div>
            <p className="settings-hint">
              {settings?.hasPerplexityKey
                ? 'Key is configured. Enables real-time search for current events.'
                : 'Enables real-time search. Get one at perplexity.ai'}
            </p>
          </div>
        </section>

        <section className="settings-section">
          <h2>Default Model</h2>
          <div className="settings-field">
            <div className="settings-model-options">
              <button
                className={`settings-model-btn ${settings?.defaultModel === 'openai' ? 'settings-model-btn--active' : ''}`}
                onClick={() => {
                  bridge.send({
                    type: 'saveSettings',
                    payload: { defaultModel: 'openai' },
                  });
                }}
                disabled={!settings?.hasOpenAIKey}
              >
                <span className="settings-model-name">OpenAI</span>
                <span className="settings-model-detail">GPT-4o</span>
              </button>
              <button
                className={`settings-model-btn ${settings?.defaultModel === 'anthropic' ? 'settings-model-btn--active' : ''}`}
                onClick={() => {
                  bridge.send({
                    type: 'saveSettings',
                    payload: { defaultModel: 'anthropic' },
                  });
                }}
                disabled={!settings?.hasAnthropicKey}
              >
                <span className="settings-model-name">Anthropic</span>
                <span className="settings-model-detail">Claude Sonnet</span>
              </button>
            </div>
            <p className="settings-hint">
              Select the default AI provider for responses. Requires the corresponding API key to be configured.
            </p>
          </div>
        </section>

        <section className="settings-section">
          <h2>Smart Routing (Perplexity)</h2>
          <div className="settings-field">
            <label
              className="settings-toggle-label"
              title={!settings?.hasPerplexityKey ? 'Requires Perplexity API key' : undefined}
            >
              <input
                type="checkbox"
                checked={settings?.smartRoutingEnabled ?? false}
                onChange={(e) => {
                  bridge.send({
                    type: 'saveSettings',
                    payload: { smartRoutingEnabled: e.target.checked },
                  });
                }}
                disabled={!settings?.hasPerplexityKey}
              />
              <span>Smart Routing</span>
            </label>
            <p className="settings-hint">
              {settings?.hasPerplexityKey
                ? 'When enabled, a local AI model analyzes your query to route it optimally: current events and real-time data go to Perplexity search, while knowledge questions go to GPT.'
                : 'Requires Perplexity API key. When enabled, queries are automatically routed to the best AI backend.'}
            </p>
            {settings?.smartRoutingEnabled && settings?.hasPerplexityKey && (
              <p className="settings-classifier-status">
                {settings.classifierError ? (
                  <span className="classifier-error">Classifier failed: {settings.classifierError}</span>
                ) : settings.classifierLoading && !settings.classifierReady ? (
                  <span className="classifier-loading">Loading local classifier...</span>
                ) : settings.classifierReady ? (
                  <span className="classifier-ready">Local classifier ready</span>
                ) : null}
              </p>
            )}
          </div>
        </section>

        <section className="settings-section">
          <h2>Appearance</h2>
          <div className="settings-field">
            <label>Theme</label>
            <div className="settings-appearance-options">
              <button
                className={`settings-appearance-btn ${settings?.appearance === 'light' ? 'settings-appearance-btn--active' : ''}`}
                onClick={() => {
                  bridge.send({
                    type: 'saveSettings',
                    payload: { appearance: 'light' },
                  });
                }}
              >
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <circle cx="12" cy="12" r="5" />
                  <line x1="12" y1="1" x2="12" y2="3" />
                  <line x1="12" y1="21" x2="12" y2="23" />
                  <line x1="4.22" y1="4.22" x2="5.64" y2="5.64" />
                  <line x1="18.36" y1="18.36" x2="19.78" y2="19.78" />
                  <line x1="1" y1="12" x2="3" y2="12" />
                  <line x1="21" y1="12" x2="23" y2="12" />
                  <line x1="4.22" y1="19.78" x2="5.64" y2="18.36" />
                  <line x1="18.36" y1="5.64" x2="19.78" y2="4.22" />
                </svg>
                Light
              </button>
              <button
                className={`settings-appearance-btn ${settings?.appearance === 'dark' ? 'settings-appearance-btn--active' : ''}`}
                onClick={() => {
                  bridge.send({
                    type: 'saveSettings',
                    payload: { appearance: 'dark' },
                  });
                }}
              >
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
                </svg>
                Dark
              </button>
              <button
                className={`settings-appearance-btn ${settings?.appearance === 'system' ? 'settings-appearance-btn--active' : ''}`}
                onClick={() => {
                  bridge.send({
                    type: 'saveSettings',
                    payload: { appearance: 'system' },
                  });
                }}
              >
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <rect x="2" y="3" width="20" height="14" rx="2" ry="2" />
                  <line x1="8" y1="21" x2="16" y2="21" />
                  <line x1="12" y1="17" x2="12" y2="21" />
                </svg>
                System
              </button>
            </div>
          </div>
        </section>

        <section className="settings-section">
          <h2>Keyboard Shortcuts</h2>
          <div className="settings-shortcuts">
            <div className="shortcut-row">
              <span className="shortcut-keys">Cmd+Enter</span>
              <span className="shortcut-desc">Think with AI</span>
            </div>
            <div className="shortcut-row">
              <span className="shortcut-keys">Enter</span>
              <span className="shortcut-desc">New cell (at end of content)</span>
            </div>
            <div className="shortcut-row">
              <span className="shortcut-keys">Backspace</span>
              <span className="shortcut-desc">Delete empty cell</span>
            </div>
            <div className="shortcut-row">
              <span className="shortcut-keys">Arrow Up/Down</span>
              <span className="shortcut-desc">Navigate between cells</span>
            </div>
          </div>
        </section>

        <section className="settings-section">
          <h2>About</h2>
          <p className="settings-about">
            Ticker V2 - An AI-augmented research space.
            <br />
            Think <em>through</em> documents, not just <em>about</em> them.
          </p>
        </section>
      </div>
    </div>
  );
}

// Usage display component
interface UsageDisplayProps {
  limits: Limits;
  usage: Usage;
}

function UsageDisplay({ limits, usage }: UsageDisplayProps) {
  const formatNumber = (n: number): string => {
    if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
    if (n >= 1_000) return `${(n / 1_000).toFixed(0)}K`;
    return n.toString();
  };

  // Format reset time from server-provided ISO timestamp, or calculate fallback
  const formatResetTime = (resetAt: string | null, type: 'daily' | 'monthly'): string => {
    const now = new Date();

    // Use server-provided timestamp if available
    if (resetAt) {
      const resetDate = new Date(resetAt);
      const diffMs = resetDate.getTime() - now.getTime();

      if (diffMs <= 0) {
        return 'Resets soon';
      }

      const diffMins = Math.floor(diffMs / (1000 * 60));
      const diffHours = Math.floor(diffMs / (1000 * 60 * 60));
      const diffDays = Math.floor(diffMs / (1000 * 60 * 60 * 24));

      if (diffDays > 1) {
        return `Resets in ${diffDays} days`;
      } else if (diffDays === 1) {
        return 'Resets tomorrow';
      } else if (diffHours > 0) {
        return `Resets in ${diffHours}h ${diffMins % 60}m`;
      }
      return `Resets in ${diffMins}m`;
    }

    // Fallback: calculate based on UTC if server timestamp not available
    if (type === 'daily') {
      const tomorrow = new Date(Date.UTC(
        now.getUTCFullYear(),
        now.getUTCMonth(),
        now.getUTCDate() + 1,
        0, 0, 0
      ));
      const diffMs = tomorrow.getTime() - now.getTime();
      const diffHours = Math.floor(diffMs / (1000 * 60 * 60));
      const diffMins = Math.floor((diffMs % (1000 * 60 * 60)) / (1000 * 60));

      if (diffHours > 0) {
        return `Resets in ${diffHours}h ${diffMins}m`;
      }
      return `Resets in ${diffMins}m`;
    } else {
      const nextMonth = new Date(Date.UTC(
        now.getUTCFullYear(),
        now.getUTCMonth() + 1,
        1, 0, 0, 0
      ));
      const diffMs = nextMonth.getTime() - now.getTime();
      const diffDays = Math.floor(diffMs / (1000 * 60 * 60 * 24));

      if (diffDays > 1) {
        return `Resets in ${diffDays} days`;
      } else if (diffDays === 1) {
        return 'Resets tomorrow';
      }
      return 'Resets soon';
    }
  };

  const dailyUsed = usage.tokensToday ?? 0;
  const dailyLimit = limits.tokensPerDay ?? 100000;
  const dailyPercent = dailyLimit > 0 ? Math.min((dailyUsed / dailyLimit) * 100, 100) : 0;
  const dailyExceeded = dailyUsed >= dailyLimit;
  const dailyWarning = dailyPercent >= 80 && !dailyExceeded;

  const monthlyUsed = usage.tokensThisMonth ?? 0;
  const monthlyLimit = limits.tokensPerMonth ?? 1000000;
  const monthlyPercent = monthlyLimit > 0 ? Math.min((monthlyUsed / monthlyLimit) * 100, 100) : 0;
  const monthlyExceeded = monthlyUsed >= monthlyLimit;
  const monthlyWarning = monthlyPercent >= 80 && !monthlyExceeded;

  return (
    <div className="usage-display">
      <div className="usage-item">
        <div className="usage-header">
          <span className="usage-label">Daily Tokens</span>
          {dailyExceeded && <span className="usage-badge usage-badge--error">LIMIT</span>}
          {dailyWarning && <span className="usage-badge usage-badge--warning">80%+</span>}
        </div>
        <div className={`usage-bar ${dailyExceeded ? 'usage-bar--error' : dailyWarning ? 'usage-bar--warning' : ''}`}>
          <div className="usage-bar-fill" style={{ width: `${dailyPercent}%` }} />
        </div>
        <div className="usage-meta">
          <span className="usage-count">{formatNumber(dailyUsed)} / {formatNumber(dailyLimit)}</span>
          <span className="usage-reset">
            {dailyExceeded
              ? `Daily limit reached. ${formatResetTime(usage.dayResetAt, 'daily')}`
              : formatResetTime(usage.dayResetAt, 'daily')}
          </span>
        </div>
      </div>

      <div className="usage-item">
        <div className="usage-header">
          <span className="usage-label">Monthly Tokens</span>
          {monthlyExceeded && <span className="usage-badge usage-badge--error">LIMIT</span>}
          {monthlyWarning && <span className="usage-badge usage-badge--warning">80%+</span>}
        </div>
        <div className={`usage-bar ${monthlyExceeded ? 'usage-bar--error' : monthlyWarning ? 'usage-bar--warning' : ''}`}>
          <div className="usage-bar-fill" style={{ width: `${monthlyPercent}%` }} />
        </div>
        <div className="usage-meta">
          <span className="usage-count">{formatNumber(monthlyUsed)} / {formatNumber(monthlyLimit)}</span>
          <span className="usage-reset">
            {monthlyExceeded
              ? `Monthly limit reached. ${formatResetTime(usage.monthResetAt, 'monthly')}`
              : formatResetTime(usage.monthResetAt, 'monthly')}
          </span>
        </div>
      </div>
    </div>
  );
}
