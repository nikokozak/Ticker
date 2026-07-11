import { useEffect, useRef, type DialogHTMLAttributes, type MouseEvent } from 'react';

interface ModalProps extends Omit<DialogHTMLAttributes<HTMLDialogElement>, 'open'> {
  onRequestClose: () => void;
}

export function Modal({
  children,
  className = '',
  onClick,
  onRequestClose,
  ...props
}: ModalProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const dialog = dialogRef.current;
    const previousFocus = document.activeElement instanceof HTMLElement
      ? document.activeElement
      : null;
    dialog?.showModal();

    return () => {
      if (dialog?.open) dialog.close();
      window.requestAnimationFrame(() => {
        if (previousFocus?.isConnected) previousFocus.focus();
      });
    };
  }, []);

  const handleClick = (event: MouseEvent<HTMLDialogElement>) => {
    onClick?.(event);
    if (event.defaultPrevented || event.target !== event.currentTarget) return;

    const rect = event.currentTarget.getBoundingClientRect();
    const outside = event.clientX < rect.left || event.clientX > rect.right ||
      event.clientY < rect.top || event.clientY > rect.bottom;
    if (outside) onRequestClose();
  };

  return (
    <dialog
      {...props}
      ref={dialogRef}
      className={`modal-dialog ${className}`.trim()}
      onCancel={(event) => {
        event.preventDefault();
        onRequestClose();
      }}
      onClick={handleClick}
    >
      {children}
    </dialog>
  );
}
