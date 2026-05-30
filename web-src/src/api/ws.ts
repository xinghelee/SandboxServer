// Single multiplexed WebSocket client.
// Connects to /__sandbox/ws (with ?token=... only when auth is enabled), supports subscribe/unsubscribe per
// channel, dispatches typed messages to listeners, auto-reconnects with
// exponential backoff, and resumes by replaying the last-seen seq per channel.

import { getToken } from './auth';
import type { WsChannel, WsServerMessage } from './types';

type Listener = (msg: WsServerMessage) => void;
type StatusListener = (status: WsStatus) => void;

export type WsStatus = 'connecting' | 'open' | 'closed';

interface ClientMessage {
  op: 'subscribe' | 'unsubscribe';
  channel: WsChannel;
  sinceSeq?: number;
}

const MIN_BACKOFF = 500;
const MAX_BACKOFF = 15000;

export class SandboxSocket {
  private ws: WebSocket | null = null;
  private status: WsStatus = 'closed';
  private backoff = MIN_BACKOFF;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private closedByUser = false;

  // channel -> listener set
  private listeners = new Map<WsChannel, Set<Listener>>();
  // channel -> ref count of subscribers
  private subscriptions = new Map<WsChannel, number>();
  // channel -> last seq seen (for resume)
  private lastSeq = new Map<WsChannel, number>();

  private statusListeners = new Set<StatusListener>();

  private wsUrl(): string {
    const loc = window.location;
    const proto = loc.protocol === 'https:' ? 'wss:' : 'ws:';
    const token = getToken();
    const tokenQs = token ? `?token=${encodeURIComponent(token)}` : '';
    return `${proto}//${loc.host}/__sandbox/ws${tokenQs}`;
  }

  connect(): void {
    this.closedByUser = false;
    if (this.ws && (this.status === 'open' || this.status === 'connecting')) return;
    this.openSocket();
  }

  private openSocket(): void {
    this.setStatus('connecting');
    let ws: WebSocket;
    try {
      ws = new WebSocket(this.wsUrl());
    } catch {
      this.scheduleReconnect();
      return;
    }
    this.ws = ws;

    ws.onopen = () => {
      this.backoff = MIN_BACKOFF;
      this.setStatus('open');
      // Re-subscribe everything we care about, resuming from last seq.
      for (const [channel, count] of this.subscriptions) {
        if (count > 0) this.sendSubscribe(channel);
      }
    };

    ws.onmessage = (ev) => {
      let msg: WsServerMessage;
      try {
        msg = JSON.parse(ev.data as string) as WsServerMessage;
      } catch {
        return;
      }
      if (!msg || typeof msg.channel !== 'string') return;
      if (typeof msg.seq === 'number') {
        const prev = this.lastSeq.get(msg.channel) ?? 0;
        if (msg.seq > prev) this.lastSeq.set(msg.channel, msg.seq);
      }
      const set = this.listeners.get(msg.channel);
      if (set) {
        for (const fn of set) {
          try {
            fn(msg);
          } catch {
            /* listener errors must not break the pump */
          }
        }
      }
    };

    ws.onclose = () => {
      this.ws = null;
      this.setStatus('closed');
      if (!this.closedByUser) this.scheduleReconnect();
    };

    ws.onerror = () => {
      // The close handler drives reconnect; just ensure the socket tears down.
      try {
        ws.close();
      } catch {
        /* ignore */
      }
    };
  }

  private scheduleReconnect(): void {
    if (this.closedByUser) return;
    if (this.reconnectTimer) return;
    const delay = this.backoff;
    this.backoff = Math.min(this.backoff * 2, MAX_BACKOFF);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      if (!this.closedByUser) this.openSocket();
    }, delay);
  }

  private send(msg: ClientMessage): void {
    if (this.ws && this.status === 'open') {
      try {
        this.ws.send(JSON.stringify(msg));
      } catch {
        /* will resync on reconnect */
      }
    }
  }

  private sendSubscribe(channel: WsChannel): void {
    const sinceSeq = this.lastSeq.get(channel);
    const msg: ClientMessage = { op: 'subscribe', channel };
    if (typeof sinceSeq === 'number' && sinceSeq > 0) msg.sinceSeq = sinceSeq;
    this.send(msg);
  }

  // Subscribe a listener to a channel. Returns an unsubscribe function.
  subscribe(channel: WsChannel, listener: Listener): () => void {
    let set = this.listeners.get(channel);
    if (!set) {
      set = new Set();
      this.listeners.set(channel, set);
    }
    set.add(listener);

    const count = (this.subscriptions.get(channel) ?? 0) + 1;
    this.subscriptions.set(channel, count);
    if (count === 1) {
      this.connect();
      this.sendSubscribe(channel);
    }

    let active = true;
    return () => {
      if (!active) return;
      active = false;
      const s = this.listeners.get(channel);
      if (s) {
        s.delete(listener);
        if (s.size === 0) this.listeners.delete(channel);
      }
      const remaining = (this.subscriptions.get(channel) ?? 1) - 1;
      if (remaining <= 0) {
        this.subscriptions.delete(channel);
        this.send({ op: 'unsubscribe', channel });
      } else {
        this.subscriptions.set(channel, remaining);
      }
    };
  }

  onStatus(listener: StatusListener): () => void {
    this.statusListeners.add(listener);
    listener(this.status);
    return () => this.statusListeners.delete(listener);
  }

  private setStatus(status: WsStatus): void {
    if (this.status === status) return;
    this.status = status;
    for (const fn of this.statusListeners) {
      try {
        fn(status);
      } catch {
        /* ignore */
      }
    }
  }

  getStatus(): WsStatus {
    return this.status;
  }

  close(): void {
    this.closedByUser = true;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.ws) {
      try {
        this.ws.close();
      } catch {
        /* ignore */
      }
      this.ws = null;
    }
    this.setStatus('closed');
  }
}

// Shared app-wide socket instance.
export const socket = new SandboxSocket();
