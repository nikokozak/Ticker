import { useToastStore } from '../store/toastStore';
import { XIcon } from './icons';

/**
 * Bottom-right toast stack for transient notifications.
 * Renders globally so errors are visible across all views.
 */
export function ToastStack() {
  // IMPORTANT:
  // Select individual fields rather than returning a new object from the selector.
  // Returning a new object each time makes the snapshot unstable and can trigger
  // React's `useSyncExternalStore` "getSnapshot should be cached" warning / loops.
  const toasts = useToastStore((state) => state.toasts);
  const removeToast = useToastStore((state) => state.removeToast);
  const clearToasts = useToastStore((state) => state.clearToasts);

  if (toasts.length === 0) return null;

  const handleCopy = async (message: string) => {
    try {
      await navigator.clipboard.writeText(message);
    } catch {
      // Fallback: do nothing on clipboard failure (rare)
    }
  };

  // aria-live lets assistive tech announce new toasts without stealing focus.
  return (
    <div
      className="toast-stack"
      aria-live="polite"
      aria-relevant="additions removals"
    >
      {toasts.length > 1 && (
        <button
          className="toast-clear-all"
          type="button"
          onClick={clearToasts}
        >
          Clear all
        </button>
      )}
      {toasts.map((toast) => (
        <div
          key={toast.id}
          className="toast"
          data-kind={toast.kind}
          role={toast.kind === 'error' ? 'alert' : 'status'}
        >
          <div className="toast-message">{toast.message}</div>
          <div className="toast-actions">
            {(toast.kind === 'error' || toast.kind === 'warning') && (
              <button
                className="toast-copy"
                type="button"
                onClick={() => handleCopy(toast.message)}
                aria-label="Copy error message"
              >
                Copy
              </button>
            )}
            <button
              className="toast-dismiss"
              type="button"
              onClick={() => removeToast(toast.id)}
              aria-label="Dismiss notification"
            >
              <XIcon size={14} />
            </button>
          </div>
        </div>
      ))}
    </div>
  );
}
