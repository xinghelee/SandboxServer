import { useState, useRef, useCallback } from 'preact/hooks';
import { copyText } from '../util/clipboard';
import { useI18n } from '../i18n';

interface Props {
  // A string, or a getter evaluated on click (so large bodies aren't stringified until needed).
  text: string | null | undefined | (() => string | null | undefined);
  title?: string;
  label?: string;
  class?: string;
}

/** Small ghost button that copies `text` and flashes a transient copied/failed state. */
export function CopyButton({ text, title, label, class: cls }: Props) {
  const { t } = useI18n();
  const [state, setState] = useState<'idle' | 'ok' | 'fail'>('idle');
  const timer = useRef<number | undefined>(undefined);

  const value = typeof text === 'function' ? undefined : text;
  const disabled = typeof text !== 'function' && (value == null || value === '');

  const onClick = useCallback(
    async (e: MouseEvent) => {
      e.stopPropagation();
      const v = typeof text === 'function' ? text() : text;
      if (v == null || v === '') return;
      const ok = await copyText(v);
      setState(ok ? 'ok' : 'fail');
      clearTimeout(timer.current);
      timer.current = window.setTimeout(() => setState('idle'), 1400);
    },
    [text],
  );

  const tip = title ?? t('copy.title');
  return (
    <button
      type="button"
      class={`copy-btn ${state} ${cls ?? ''}`}
      title={tip}
      aria-label={tip}
      disabled={disabled}
      onClick={onClick}
    >
      {state === 'ok' ? t('copy.done') : state === 'fail' ? t('copy.fail') : label ?? t('copy.label')}
    </button>
  );
}
