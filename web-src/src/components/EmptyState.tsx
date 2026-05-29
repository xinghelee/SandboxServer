import type { ComponentChildren } from 'preact';
import { useI18n } from '../i18n';

interface Props {
  icon?: string;
  /** Raw title, or a translation key via `titleKey`. */
  title?: string;
  titleKey?: string;
  /** Translation key for the sub text (overridden by `children` if provided). */
  subKey?: string;
  children?: ComponentChildren;
  /** Raw tag, or a translation key via `tagKey`. */
  tag?: string;
  tagKey?: string;
}

export function EmptyState({ icon = '○', title, titleKey, subKey, children, tag, tagKey }: Props) {
  const { t } = useI18n();
  const heading = titleKey ? t(titleKey) : (title ?? '');
  const tagText = tagKey ? t(tagKey) : tag;
  const sub = children ?? (subKey ? t(subKey) : null);
  return (
    <div class="empty-state">
      <div class="es-icon">{icon}</div>
      <div class="es-title">{heading}</div>
      {sub ? <div class="es-sub">{sub}</div> : null}
      {tagText ? <div class="tag">{tagText}</div> : null}
    </div>
  );
}
