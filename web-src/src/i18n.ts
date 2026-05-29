// Tiny i18n store: a string table, a current-language signal persisted to localStorage,
// and a Preact hook that re-renders subscribers on change. No dependencies.

import { useEffect, useState } from 'preact/hooks';

export type Lang = 'en' | 'zh';

const STORAGE_KEY = 'sbx_lang';

type Dict = Record<string, string>;

const EN: Dict = {
  'brand.sub': 'sandbox inspector',
  'prompt.path': '~/__sandbox',

  'hdr.build': 'build',
  'hdr.binding': 'binding',
  'hdr.device': 'host',
  'hdr.app': 'bundle',
  'hdr.theme': 'theme',
  'hdr.lang': 'language',
  'hdr.crt': 'CRT',

  'ws.live': 'LIVE',
  'ws.connecting': 'LINK…',
  'ws.offline': 'OFFLINE',

  'nav.modules': 'modules',
  'nav.foot': 'served over localhost · debug-only',

  'boot.0': 'initializing sbx terminal',
  'boot.1': 'establishing link',
  'boot.2': 'authenticating session token',
  'boot.3': 'enumerating plugins',

  'net.title': 'network',
  'net.count': '{n} req',
  'net.filter': 'filter  method / url / status',
  'net.refresh': 'reload',
  'net.clear': 'flush',
  'net.loading': 'reading capture buffer…',
  'net.empty.title': 'no requests captured',
  'net.empty.sub': 'traffic streams in live as the app makes URLSession requests.',
  'net.col.method': 'method',
  'net.col.url': 'url',
  'net.col.status': 'code',
  'net.col.dur': 'time',
  'net.col.size': 'size',
  'net.col.clock': 'at',

  'd.status': 'status',
  'd.duration': 'duration',
  'd.started': 'started',
  'd.reqsize': 'req size',
  'd.respsize': 'resp size',
  'd.reqheaders': 'request headers',
  'd.reqbody': 'request body',
  'd.respheaders': 'response headers',
  'd.respbody': 'response body',
  'd.noheaders': 'no headers',
  'd.emptybody': 'empty body',
  'd.loading': 'fetching transaction…',
  'd.close': 'close',

  'fs.title': 'files',
  'fs.loading': 'reading directory…',
  'fs.empty': 'empty directory',
  'fs.up': 'up',
  'fs.roots': 'roots',
  'fs.col.name': 'name',
  'fs.col.size': 'size',
  'fs.col.modified': 'modified',
  'fs.preview': 'preview',
  'fs.download': 'download',
  'fs.edit': 'edit',
  'fs.save': 'save',
  'fs.cancel': 'cancel',
  'fs.delete': 'delete',
  'fs.confirmDelete': 'Delete "{name}"?',
  'fs.binary': 'Binary file · {size}',
  'fs.saved': 'saved',
  'fs.notimpl.title': 'filesystem browser — v2',
  'fs.notimpl.sub': 'the plugin is registered and its routes reserved; the device returns not_implemented for now.',

  'db.title': 'databases',
  'db.found': '{n} found',
  'db.loading': 'discovering databases…',
  'db.notimpl.title': 'discovery unavailable',
  'db.notimpl.sub': 'database discovery is not available on this device build.',
  'db.empty.title': 'no databases discovered',
  'db.empty.sub': 'no SQLite, Core Data, or Realm stores were found in the sandbox.',
  'db.readonly': 'read-only',
  'db.soon.title': 'browse & query — v2',
  'db.soon.sub': 'tables, schema inspection, and the query console arrive in a later version.',
  'db.back': 'databases',
  'db.tables': 'tables',
  'db.notables': 'no tables',
  'db.rows': '{n} rows',
  'db.schema': 'schema',
  'db.fk': 'foreign keys',
  'db.pk': 'PK',
  'db.notnull': 'NOT NULL',
  'db.run': 'run',
  'db.sql.ph': 'SELECT * FROM …   (read-only)',
  'db.loadmore': 'load more',
  'db.readonlyNote': 'read-only · writes are blocked',

  'logs.title': 'logs',
  'logs.count': '{n} lines',
  'logs.filter': 'filter messages',
  'logs.clear': 'clear',
  'logs.pause': 'pause',
  'logs.resume': 'resume',
  'logs.follow': 'follow',
  'logs.loading': 'reading log buffer…',
  'logs.empty.title': 'no log lines yet',
  'logs.empty.sub': 'SDK logs, app logs (SandboxServer.log), and — when console capture is on — print/NSLog stream in live.',
  'logs.level.all': 'all',
  'logs.level.debug': 'debug',
  'logs.level.info': 'info',
  'logs.level.warn': 'warn',
  'logs.level.error': 'error',

  'screen.title': 'screen',
  'screen.loading': 'querying screen…',
  'screen.waiting': 'waiting for first frame…',
  'screen.pause': 'pause',
  'screen.resume': 'resume',
  'screen.interact.on': 'interactive',
  'screen.interact.off': 'view only',
  'screen.hint.tap': 'click the screen to tap · click a text field, then type below',
  'screen.hint.look': 'view-only — enable “interactive” to tap and type',
  'screen.text.ph': 'text to type / paste into the focused field',
  'screen.type': 'type',
  'screen.paste': 'paste',
  'screen.clearType': 'clear + type',
  'screen.unsupported.title': 'screen control unavailable',
  'screen.unsupported.sub': 'live mirror + tap/type are iOS-only; this device build has no UIKit screen to capture.',

  'err.unauth.title': 'unauthorized — 401',
  'err.unauth.sub': 'no valid session token. open the console using the link the SDK printed, which carries a one-time ?token= bootstrap.',
  'err.fatal.title': 'cannot reach the device',
  'err.connecting': 'connecting to device…',
  'err.noplugins': 'the device reported no plugins.',
  'err.unknownpanel': 'no built-in renderer for this plugin.',
  'warn.nondebug': 'this app is a {build} build — SandboxServer is intended for debug builds only.',
};

const ZH: Dict = {
  'brand.sub': '沙盒检查器',
  'prompt.path': '~/__sandbox',

  'hdr.build': '构建',
  'hdr.binding': '绑定',
  'hdr.device': '主机',
  'hdr.app': '应用',
  'hdr.theme': '主题',
  'hdr.lang': '语言',
  'hdr.crt': '扫描线',

  'ws.live': '实时',
  'ws.connecting': '连接中…',
  'ws.offline': '离线',

  'nav.modules': '模块',
  'nav.foot': '经 localhost 提供 · 仅调试',

  'boot.0': '正在初始化 sbx 终端',
  'boot.1': '正在建立连接',
  'boot.2': '正在校验会话令牌',
  'boot.3': '正在枚举插件',

  'net.title': '网络',
  'net.count': '{n} 条',
  'net.filter': '过滤  方法 / 网址 / 状态',
  'net.refresh': '刷新',
  'net.clear': '清空',
  'net.loading': '正在读取抓包缓冲…',
  'net.empty.title': '尚未捕获请求',
  'net.empty.sub': '应用发起 URLSession 请求时,流量会实时出现在这里。',
  'net.col.method': '方法',
  'net.col.url': '网址',
  'net.col.status': '状态',
  'net.col.dur': '耗时',
  'net.col.size': '大小',
  'net.col.clock': '时刻',

  'd.status': '状态',
  'd.duration': '耗时',
  'd.started': '开始',
  'd.reqsize': '请求大小',
  'd.respsize': '响应大小',
  'd.reqheaders': '请求头',
  'd.reqbody': '请求体',
  'd.respheaders': '响应头',
  'd.respbody': '响应体',
  'd.noheaders': '无头部',
  'd.emptybody': '空请求体',
  'd.loading': '正在获取请求详情…',
  'd.close': '关闭',

  'fs.title': '文件',
  'fs.loading': '正在读取目录…',
  'fs.empty': '空目录',
  'fs.up': '上级',
  'fs.roots': '根目录',
  'fs.col.name': '名称',
  'fs.col.size': '大小',
  'fs.col.modified': '修改时间',
  'fs.preview': '预览',
  'fs.download': '下载',
  'fs.edit': '编辑',
  'fs.save': '保存',
  'fs.cancel': '取消',
  'fs.delete': '删除',
  'fs.confirmDelete': '删除“{name}”?',
  'fs.binary': '二进制文件 · {size}',
  'fs.saved': '已保存',
  'fs.notimpl.title': '文件浏览 — v2',
  'fs.notimpl.sub': '插件已注册、路由已预留;设备目前返回 not_implemented。',

  'db.title': '数据库',
  'db.found': '发现 {n} 个',
  'db.loading': '正在发现数据库…',
  'db.notimpl.title': '发现不可用',
  'db.notimpl.sub': '当前设备构建不支持数据库发现。',
  'db.empty.title': '未发现数据库',
  'db.empty.sub': '沙盒中未找到 SQLite、Core Data 或 Realm 存储。',
  'db.readonly': '只读',
  'db.soon.title': '浏览与查询 — v2',
  'db.soon.sub': '表浏览、结构检查与查询控制台将在后续版本提供。',
  'db.back': '数据库',
  'db.tables': '表',
  'db.notables': '没有表',
  'db.rows': '{n} 行',
  'db.schema': '结构',
  'db.fk': '外键',
  'db.pk': '主键',
  'db.notnull': '非空',
  'db.run': '执行',
  'db.sql.ph': 'SELECT * FROM …   (只读)',
  'db.loadmore': '加载更多',
  'db.readonlyNote': '只读 · 写入被拦截',

  'logs.title': '日志',
  'logs.count': '{n} 行',
  'logs.filter': '过滤日志内容',
  'logs.clear': '清空',
  'logs.pause': '暂停',
  'logs.resume': '继续',
  'logs.follow': '跟随',
  'logs.loading': '正在读取日志缓冲…',
  'logs.empty.title': '暂无日志',
  'logs.empty.sub': 'SDK 日志、应用日志(SandboxServer.log),以及开启控制台捕获后的 print/NSLog 都会实时出现在这里。',
  'logs.level.all': '全部',
  'logs.level.debug': '调试',
  'logs.level.info': '信息',
  'logs.level.warn': '警告',
  'logs.level.error': '错误',

  'screen.title': '屏幕',
  'screen.loading': '正在查询屏幕…',
  'screen.waiting': '正在等待首帧…',
  'screen.pause': '暂停',
  'screen.resume': '继续',
  'screen.interact.on': '可操作',
  'screen.interact.off': '仅查看',
  'screen.hint.tap': '点击画面即可点按 · 先点输入框,再在下方输入',
  'screen.hint.look': '仅查看 —— 开启“可操作”后可点按和输入',
  'screen.text.ph': '要输入 / 粘贴到当前输入框的文本',
  'screen.type': '输入',
  'screen.paste': '粘贴',
  'screen.clearType': '清空并输入',
  'screen.unsupported.title': '屏幕控制不可用',
  'screen.unsupported.sub': '实时镜像 + 点按/输入仅限 iOS;当前设备构建没有可捕获的 UIKit 屏幕。',

  'err.unauth.title': '未授权 — 401',
  'err.unauth.sub': '没有有效的会话令牌。请用 SDK 打印的链接打开控制台,它带有一次性的 ?token= 引导参数。',
  'err.fatal.title': '无法连接到设备',
  'err.connecting': '正在连接设备…',
  'err.noplugins': '设备未报告任何插件。',
  'err.unknownpanel': '该插件没有内置渲染器。',
  'warn.nondebug': '该应用是 {build} 构建 —— SandboxServer 仅用于 debug 构建。',
};

const TABLES: Record<Lang, Dict> = { en: EN, zh: ZH };

function detect(): Lang {
  const stored = (typeof localStorage !== 'undefined' && localStorage.getItem(STORAGE_KEY)) as Lang | null;
  if (stored === 'en' || stored === 'zh') return stored;
  return typeof navigator !== 'undefined' && navigator.language.toLowerCase().startsWith('zh') ? 'zh' : 'en';
}

let current: Lang = detect();
const subscribers = new Set<() => void>();

if (typeof document !== 'undefined') document.documentElement.lang = current === 'zh' ? 'zh-CN' : 'en';

export function getLang(): Lang {
  return current;
}

export function setLang(lang: Lang): void {
  if (lang === current) return;
  current = lang;
  try {
    localStorage.setItem(STORAGE_KEY, lang);
  } catch {
    /* private mode */
  }
  if (typeof document !== 'undefined') document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
  subscribers.forEach((fn) => fn());
}

export function t(key: string, vars?: Record<string, string | number>): string {
  let s = TABLES[current][key] ?? TABLES.en[key] ?? key;
  if (vars) for (const [k, v] of Object.entries(vars)) s = s.replace(`{${k}}`, String(v));
  return s;
}

/** Hook returning a translator bound to the live language, re-rendering on change. */
export function useI18n() {
  const [, force] = useState(0);
  useEffect(() => {
    const fn = () => force((n) => n + 1);
    subscribers.add(fn);
    return () => {
      subscribers.delete(fn);
    };
  }, []);
  return { t, lang: current, setLang };
}
