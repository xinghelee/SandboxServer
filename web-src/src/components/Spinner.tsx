import { useEffect, useState } from 'preact/hooks';
import { useI18n } from '../i18n';

const FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

export function Loading({ label, labelKey }: { label?: string; labelKey?: string }) {
  const { t } = useI18n();
  const [i, setI] = useState(0);
  useEffect(() => {
    const id = setInterval(() => setI((n) => (n + 1) % FRAMES.length), 80);
    return () => clearInterval(id);
  }, []);
  const text = labelKey ? t(labelKey) : (label ?? '…');
  return (
    <div class="center-pad">
      <span class="spinner">{FRAMES[i]}</span>
      {text}
    </div>
  );
}
