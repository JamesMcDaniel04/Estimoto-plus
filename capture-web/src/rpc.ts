/** The first-party/native host owns authentication and estimate identity. */
export const CHANNEL = "estimoto-plus-capture";
export type Method = "captureState" | "readSavedPhoto" | "checkFrame" | "saveCapture" | "recognizeVin" | "confirmVin" | "askCaptureHelp" | "close";
type Pending = { resolve: (value: unknown) => void; reject: (error: Error) => void; timer: number };
type CaptureWindow = Window & { CaptureHost?: { postMessage: (message: string) => void }; EstimotoPlusCapture?: { receive: (message: unknown) => void } };

export class RPCError extends Error {
  constructor(message: string, public readonly status: number | null = null,
    public readonly code: "capture_superseded" | null = null) { super(message); }
}

export class CaptureRPC {
  private pending = new Map<string, Pending>();
  private seq = 0;
  private closed = false;

  constructor(private readonly host: CaptureWindow = window as CaptureWindow) {
    host.addEventListener("message", this.onBrowserMessage);
    host.EstimotoPlusCapture = { receive: this.onNativeMessage };
  }

  ready() {
    this.emit({ channel: CHANNEL, type: "ready", version: 1 });
  }

  private emit(message: object) {
    const native = this.host.CaptureHost;
    if (native) native.postMessage(JSON.stringify(message));
    else if (this.host.parent !== this.host) this.host.parent.postMessage(message, this.host.location.origin);
    else throw new Error("Open capture from your Estimoto + garage.");
  }

  private receive = (message: unknown) => {
    if (!message || typeof message !== "object") return;
    const row = message as Record<string, unknown>;
    if (row.channel !== CHANNEL) return;
    if (row.type === "pause") { this.host.dispatchEvent(new Event("capture:pause")); return; }
    if (row.type === "resume") { this.host.dispatchEvent(new Event("capture:resume")); return; }
    if (typeof row.id !== "string" || row.id.length > 80) return;
    const pending = this.pending.get(row.id);
    if (!pending) return;
    this.pending.delete(row.id);
    this.host.clearTimeout(pending.timer);
    if (row.error != null) {
      const detail = row.error && typeof row.error === "object" ? row.error as Record<string, unknown> : null;
      const message = typeof row.error === "string" ? row.error : typeof detail?.message === "string" ? detail.message : "Capture request failed. Try again.";
      const status = typeof detail?.status === "number" ? detail.status : null;
      const code = status === 409 && detail?.code === "capture_superseded" ? "capture_superseded" : null;
      pending.reject(new RPCError(message, status, code));
    }
    else pending.resolve(row.result);
  };

  private onNativeMessage = (message: unknown) => {
    try { this.receive(typeof message === "string" ? JSON.parse(message) : message); }
    catch { /* Invalid host message is ignored. */ }
  };

  private onBrowserMessage = (event: MessageEvent) => {
    if (event.origin !== this.host.location.origin || event.source !== this.host.parent || event.source === this.host) return;
    this.receive(event.data);
  };

  request<T>(method: Method, params: Record<string, unknown> = {}, timeoutMs = 30_000): Promise<T> {
    if (this.closed) return Promise.reject(new Error("Capture is closed."));
    const id = `capture-${++this.seq}-${crypto.randomUUID()}`;
    return new Promise<T>((resolve, reject) => {
      const timer = this.host.setTimeout(() => {
        this.pending.delete(id);
        reject(new Error("Capture request timed out. Retry the same photo."));
      }, timeoutMs);
      this.pending.set(id, { resolve: resolve as (value: unknown) => void, reject, timer });
      try { this.emit({ channel: CHANNEL, id, method, params }); }
      catch (error) { this.host.clearTimeout(timer); this.pending.delete(id); reject(error); }
    });
  }

  close() {
    this.closed = true;
    this.host.removeEventListener("message", this.onBrowserMessage);
    delete this.host.EstimotoPlusCapture;
    for (const pending of this.pending.values()) {
      this.host.clearTimeout(pending.timer);
      pending.reject(new Error("Capture is closed."));
    }
    this.pending.clear();
  }
}

export async function encodedPhoto(file: File): Promise<{ base64: string; mime_type: string }> {
  if (!(["image/jpeg", "image/png", "image/webp"].includes(file.type)) || file.size === 0 || file.size > 8 * 1024 * 1024) {
    throw new Error("Choose a JPEG, PNG or WebP photo under 8 MB.");
  }
  const bytes = new Uint8Array(await file.arrayBuffer());
  let result = "";
  for (let i = 0; i < bytes.length; i += 0x6000) result += String.fromCharCode(...bytes.subarray(i, i + 0x6000));
  return { base64: btoa(result), mime_type: file.type };
}
