import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import GuidedCamera from "./shared/GuidedCamera";
import { DAMAGE_AREAS, HAIL_AREAS, SUPPORTED_VEHICLE_STEPS, hailAreaSteps, requiredStepsFor, type PhotoStep } from "./shared/template";
import { CaptureRPC, encodedPhoto, RPCError } from "./rpc";

type Photo = { id: string; label: string; sha256: string | null; quality: "framing_checked" | "not_checked" };
type Suggestion = { photo_id: string; suggested_vin: string | null; confidence: number | null };
type CaptureState = { estimate_id: string; discipline: "pdr" | "collision"; vehicle: { year: number; make: string; model: string; vin: string }; photos: Photo[]; vin_suggestion: Suggestion | null };
type SaveResult = { id: string; label: string; sha256: string; quality: Photo["quality"]; warning?: string | null };
type Guidance = { ready: boolean; available: boolean; instruction: string };
type CaptureHostAPI = Pick<CaptureRPC, "request" | "ready" | "close">;
const operationIds = new WeakMap<File, string>();
const maxSavedPhotoBytes = 10 * 1024 * 1024;
type SavedImage = { id: string; sha256: string; mime_type: string; base64: string };

function SavedPhotoImage({ photo, label, rpc }: { photo: Photo; label: string; rpc: CaptureHostAPI }) {
  const [url, setUrl] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    let active = true;
    let objectUrl: string | null = null;
    setUrl(null); setFailed(false);
    void rpc.request<SavedImage>("readSavedPhoto", { photo_id: photo.id, photo_sha256: photo.sha256 }, 25_000)
      .then((image) => {
        if (!active) return;
        if (image?.id !== photo.id || image.sha256 !== photo.sha256 ||
          !["image/png", "image/jpeg", "image/webp"].includes(image.mime_type) ||
          typeof image.base64 !== "string" || !image.base64.length ||
          image.base64.length > 4 * Math.ceil(maxSavedPhotoBytes / 3) ||
          !/^[A-Za-z0-9+/]*={0,2}$/.test(image.base64)) throw new Error("Unreadable photo");
        const bytes = Uint8Array.from(atob(image.base64), (character) => character.charCodeAt(0));
        if (!bytes.length || bytes.length > maxSavedPhotoBytes) throw new Error("Unreadable photo");
        objectUrl = URL.createObjectURL(new Blob([bytes], { type: image.mime_type }));
        setUrl(objectUrl);
      }).catch(() => { if (active) setFailed(true); });
    return () => { active = false; if (objectUrl) URL.revokeObjectURL(objectUrl); };
  }, [photo.id, photo.sha256, rpc, attempt]);
  if (failed) return <div className="capture-photo-error"><p role="alert">Your photo is still saved, but its preview could not be loaded. Retry or close this guide to review it from your estimate.</p>
    <button type="button" onClick={() => setAttempt((value) => value + 1)}>Retry loading photo</button></div>;
  if (!url) return <p role="status">Loading saved photo…</p>;
  return <img className="capture-saved-image" src={url} alt={label} onError={() => { URL.revokeObjectURL(url); setUrl(null); setFailed(true); }} />;
}

function CaptureHelp({ keyName, rpc }: { keyName: string; rpc: CaptureHostAPI }) {
  const [question, setQuestion] = useState("");
  const [reply, setReply] = useState("");
  const [busy, setBusy] = useState(false);
  const status = useRef<HTMLParagraphElement>(null);
  const active = useRef(true);
  useEffect(() => { active.current = true; return () => { active.current = false; }; }, []);
  useEffect(() => { status.current?.scrollIntoView?.({ block: "nearest" }); }, [busy, reply]);
  const ask = () => {
    if (!question.trim() || busy) return;
    setReply("");
    setBusy(true);
    void rpc.request<{ reply: string }>("askCaptureHelp", { capture_key: keyName, question: question.trim().slice(0, 500) })
      .then((answer) => {
        if (!active.current) return;
        if (typeof answer?.reply !== "string" || !answer.reply.trim()) throw new Error("Empty help response");
        setReply(answer.reply);
      }).catch(() => { if (active.current) setReply("Capture help is unavailable. Follow the on-screen guide or use an existing photo. You can ask again."); })
      .finally(() => { if (active.current) setBusy(false); });
  };
  // Explicit button/Enter handling also works in an embedded camera whose host
  // blocks native form submission. Asking for help never navigates the guide.
  return <details className="capture-help">
    <summary tabIndex={0}>Ask Estibot about this photo</summary>
    <section aria-label="Photo help">
      <label htmlFor="capture-question">Your photo question</label>
      <div className="capture-help-question"><input id="capture-question" value={question} maxLength={500}
        onChange={(event) => setQuestion(event.target.value)} placeholder="How do I avoid glare?"
        onKeyDown={(event) => { if (event.key === "Enter") { event.preventDefault(); ask(); } }} />
        <button type="button" disabled={busy || !question.trim()} onClick={ask}>Ask</button></div>
      {(busy || reply) && <p ref={status} role="status" aria-live="polite">{busy ? "Asking Estibot…" : reply}</p>}
    </section>
  </details>;
}

export function CaptureApp({ rpc }: { rpc: CaptureHostAPI }) {
  const [state, setState] = useState<CaptureState | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [warning, setWarning] = useState<string | null>(null);
  const [cameraSteps, setCameraSteps] = useState<PhotoStep[] | null>(null);
  const [reviewId, setReviewId] = useState<string | null>(null);
  const [retakeKey, setRetakeKey] = useState<string | null>(null);
  const [retakeDone, setRetakeDone] = useState(false);
  const reviewHeading = useRef<HTMLHeadingElement>(null);
  const [bodyStyle, setBodyStyle] = useState("sedan");
  const [selectedPanel, setSelectedPanel] = useState("");
  const [vinInput, setVinInput] = useState("");
  const [working, setWorking] = useState(false);
  const [paused, setPaused] = useState(false);
  const alive = useRef(true);

  const refresh = useCallback(async () => {
    const next = await rpc.request<CaptureState>("captureState", {}, 12_000);
    if (!alive.current) return next;
    if (!next || !Array.isArray(next.photos) || !["pdr", "collision"].includes(next.discipline)) throw new Error("Capture state is unavailable.");
    setState(next);
    return next;
  }, []);

  useEffect(() => {
    alive.current = true;
    const pause = () => { setPaused(true); setCameraSteps(null); setReviewId(null); setRetakeKey(null); };
    const resume = () => { setPaused(false); void refresh().catch(() => setError("Refresh your garage and reopen capture.")); };
    window.addEventListener("capture:pause", pause);
    window.addEventListener("capture:resume", resume);
    try {
      rpc.ready();
      void refresh().catch((cause) => setError(cause instanceof Error ? cause.message : "Open capture from your Estimoto + garage."));
    } catch { setError("Open capture from your Estimoto + garage."); }
    return () => { alive.current = false; window.removeEventListener("capture:pause", pause); window.removeEventListener("capture:resume", resume); rpc.close(); };
  }, [refresh]);

  const saved = useMemo(() => Object.fromEntries((state?.photos ?? []).map((photo) => [photo.label, true])), [state]);
  const required = useMemo(() => requiredStepsFor(state?.discipline === "pdr" ? "hail" : "collision"), [state?.discipline]);
  const requiredCount = required.filter((step) => saved[step.key]).length;
  const photoSteps = useMemo(() => [...SUPPORTED_VEHICLE_STEPS,
    ...DAMAGE_AREAS.map((area): PhotoStep => ({ key: `panel_${area.key}`, panel: area.key, label: area.label, hint: "Fit the panel and surrounding edges in frame. Avoid glare and hold steady." })),
    ...HAIL_AREAS.flatMap((area) => hailAreaSteps(area.key))], []);
  const stepFor = (photo: Photo) => photoSteps.find((step) => step.key === photo.label);
  const labelFor = (photo: Photo) => stepFor(photo)?.label ?? photo.label.replaceAll("_", " ");
  const reviewPhoto = state?.photos.find((photo) => photo.id === reviewId);
  const cameraSaved = useMemo(() => retakeKey && !retakeDone ? { ...saved, [retakeKey]: false } : saved, [saved, retakeKey, retakeDone]);
  useEffect(() => { if (reviewId) { reviewHeading.current?.focus(); reviewHeading.current?.scrollIntoView?.({ block: "start" }); } }, [reviewId]);
  const paired = useMemo(() => HAIL_AREAS.some((area) => saved[`hail_close_${area.key}`] && saved[`hail_raking_${area.key}`]), [saved]);
  const legacyPanel = useMemo(() => HAIL_AREAS.some((area) => saved[`panel_${area.key}`]), [saved]);
  const needsDamagePanel = !retakeKey && state?.discipline === "pdr" && !paired && !legacyPanel && !!cameraSteps && !cameraSteps.some((step) => step.key.startsWith("hail_") || step.key.startsWith("panel_"));
  const vinPhoto = state?.photos.find((photo) => photo.label === "vin");
  const currentSuggestion = vinPhoto && state?.vin_suggestion?.photo_id === vinPhoto.id ? state.vin_suggestion : null;

  const startRequired = () => {
    setError(null);
    setWarning(null);
    setReviewId(null);
    setRetakeKey(null);
    setCameraSteps(required);
  };

  const review = (photo: Photo) => { setCameraSteps(null); setRetakeKey(null); setReviewId(photo.id); };
  const retake = (photo: Photo) => {
    const step = stepFor(photo);
    if (!step) return;
    setReviewId(null); setRetakeKey(photo.label); setRetakeDone(false); setError(null); setWarning(null);
    setCameraSteps([{ ...step, optional: false }]);
  };

  const startPanel = () => {
    if (!state || !selectedPanel) return;
    const catalog = state.discipline === "pdr" ? HAIL_AREAS : DAMAGE_AREAS;
    if (!catalog.some((row) => row.key === selectedPanel)) return;
    setReviewId(null); setRetakeKey(null);
    setCameraSteps(state.discipline === "pdr" ? hailAreaSteps(selectedPanel) : [{ key: `panel_${selectedPanel}`, panel: selectedPanel,
      label: catalog.find((row) => row.key === selectedPanel)?.label ?? "Damaged panel", hint: "Fit the panel and surrounding edges in frame. Avoid glare and hold steady." }]);
    setError(null);
  };

  const checkFrame = useCallback(async (file: File, key: string, body: string, _signal: AbortSignal): Promise<Guidance> => {
    const photo = await encodedPhoto(file);
    return rpc.request<Guidance>("checkFrame", { capture_key: key, body_style: body || "sedan", photo }, 25_000);
  }, []);

  const saveFrame = useCallback(async (key: string, _panel: string, file: File) => {
    const operation = operationIds.get(file) ?? crypto.randomUUID();
    operationIds.set(file, operation);
    const photo = await encodedPhoto(file);
    let result: SaveResult;
    try { result = await rpc.request<SaveResult>("saveCapture", { capture_key: key, body_style: bodyStyle, operation_id: operation, photo }, 50_000); }
    catch (cause) {
      const superseded = cause instanceof RPCError && cause.status === 409 && cause.code === "capture_superseded";
      if (cause instanceof RPCError && (cause.status === 422 || superseded)) {
        // Only a definitive rejection or the host's verified active-photo
        // conflict releases this operation. Ordinary 409s retain exact retry.
        operationIds.delete(file);
        if (superseded) await refresh().catch(() => undefined);
        const rejected = new Error(cause.message);
        rejected.name = "PhotoRejected";
        throw rejected;
      }
      throw cause;
    }
    if (!result?.id || result.label !== key || !/^[a-f0-9]{64}$/.test(result.sha256)) {
      throw new Error("Photo status is uncertain. Retry saving the same photo.");
    }
    if (result.warning) setWarning(result.warning);
    const current = await refresh();
    const active = current.photos.find((row) => row.label === key);
    if (!active || active.id !== result.id || active.sha256 !== result.sha256) {
      operationIds.delete(file);
      const conflict = new RPCError("A newer photo is saved for this step. Review it before taking another photo.", 409);
      conflict.name = "PhotoRejected";
      throw conflict;
    }
    if (retakeKey === key) setRetakeDone(true);
    return true;
  }, [bodyStyle, refresh, retakeKey]);

  const recognizeVin = () => {
    if (!vinPhoto || working) return;
    setWorking(true);
    setError(null);
    void rpc.request("recognizeVin", { photo_id: vinPhoto.id }, 40_000)
      .then(() => refresh()).catch((cause) => setError(cause instanceof Error ? cause.message : "VIN recognition is unavailable."))
      .finally(() => setWorking(false));
  };

  const confirmVin = () => {
    if (!vinPhoto || !state || working) return;
    const vin = vinInput.trim().toUpperCase();
    if (!/^[A-HJ-NPR-Z0-9]{17}$/.test(vin)) { setError("Enter the 17 VIN characters shown on the label."); return; }
    setWorking(true);
    setError(null);
    void rpc.request("confirmVin", { photo_id: vinPhoto.id, photo_sha256: vinPhoto.sha256,
      expected_vin: state.vehicle.vin ?? "", vin }, 30_000)
      .then(() => { setVinInput(""); return refresh(); })
      .catch((cause) => setError(cause instanceof Error ? cause.message : "VIN confirmation failed. Review the photo and try again."))
      .finally(() => setWorking(false));
  };

  const close = () => { setCameraSteps(null); setReviewId(null); void rpc.request("close").catch(() => undefined); };
  const finishCamera = () => {
    setCameraSteps(null);
    const replacement = state?.photos.find((photo) => photo.label === retakeKey);
    setRetakeKey(null);
    if (replacement) setReviewId(replacement.id);
  };

  if (error && !state) return <main className="capture-page"><h1>Vehicle photo capture</h1><p role="alert">{error}</p><p>Open this guide from your Estimoto + garage.</p></main>;
  if (!state) return <main className="capture-page"><h1>Vehicle photo capture</h1><p role="status">Loading your saved photo walk…</p></main>;
  const panelOptions = state.discipline === "pdr" ? HAIL_AREAS : DAMAGE_AREAS;
  return <main className="capture-page">
    <header><span className="capture-brand">estimoto +</span><button type="button" onClick={close}>Close</button></header>
    <h1>Photograph your vehicle</h1>
    <p>{state.vehicle.year} {state.vehicle.make} {state.vehicle.model}</p>
    <p>{requiredCount} of {required.length} required photos saved. This only saves evidence; submitting to a shop happens after review.</p>
    <button className="capture-primary" type="button" onClick={() => requiredCount === required.length ? review(state.photos.find((photo) => photo.label === required[0].key)!) : startRequired()} disabled={paused}>{requiredCount === required.length ? "Review required photos" : "Open guided camera"}</button>
    {paused && <p role="status">Capture paused. Return to Estimoto + to resume.</p>}
    {reviewPhoto && !paused && <section className="capture-panel capture-review" aria-labelledby="saved-photo-heading">
      <div className="capture-review-header"><h2 id="saved-photo-heading" ref={reviewHeading} tabIndex={-1}>Review saved photos</h2><button type="button" onClick={() => setReviewId(null)}>Close review</button></div>
      <label htmlFor="saved-photo">Saved photo</label><select id="saved-photo" value={reviewPhoto.id} onChange={(event) => setReviewId(event.target.value)}>{state.photos.map((photo) => <option key={photo.id} value={photo.id}>{labelFor(photo)}</option>)}</select>
      {typeof reviewPhoto.sha256 === "string" && /^[a-f0-9]{64}$/.test(reviewPhoto.sha256)
        ? <SavedPhotoImage key={`${reviewPhoto.id}:${reviewPhoto.sha256}`} photo={reviewPhoto} label={labelFor(reviewPhoto)} rpc={rpc} />
        : <div><p role="status">This older photo is saved. View it from your estimate, or retake it to enable review here.</p><button type="button" onClick={close}>Return to estimate</button></div>}
      <p>{reviewPhoto.quality === "not_checked" ? "Framing was not checked for this photo." : "Framing checked. Confirm the details are clear before submitting."}</p>
      {stepFor(reviewPhoto) && <button type="button" onClick={() => retake(reviewPhoto)}>Retake this photo</button>}
      <p className="capture-review-note">The saved photo stays in place until its replacement finishes saving.</p>
    </section>}
    <ul className="capture-list">{required.map((step) => <li key={step.key}><span>{step.label}</span>{saved[step.key] ? <button type="button" disabled={paused} aria-label={`Review ${step.label}`} onClick={() => review(state.photos.find((photo) => photo.label === step.key)!)}>Review</button> : <strong>Needed</strong>}</li>)}</ul>
    {state.photos.length > 0 && requiredCount !== required.length && <button className="capture-review-all" type="button" disabled={paused} onClick={() => review(state.photos[0])}>Review all saved photos</button>}
    {state.photos.some((photo) => photo.quality === "not_checked") && <p className="capture-note">Some saved photos have not had framing checked. Review them before submitting.</p>}
    {warning && <p role="status">{warning}</p>}
    <section className="capture-panel"><h2>{state.discipline === "pdr" ? "Damaged PDR area" : "Additional damaged panel"}</h2>
      <p>{state.discipline === "pdr" ? "Add a close-up and an angled-light photo of the same damaged panel. The angled-light photo supports dent assessment." : "Add a close view of any damaged panel."}</p>
      <select aria-label="Damaged panel" value={selectedPanel} onChange={(event) => setSelectedPanel(event.target.value)}><option value="">Choose a panel</option>{panelOptions.map((row) => <option key={row.key} value={row.key}>{row.label}</option>)}</select>
      <button type="button" disabled={!selectedPanel || paused} onClick={startPanel}>Capture selected panel</button>
      {state.discipline === "pdr" && <p role="status">{paired || legacyPanel ? "Damage evidence saved" : "A matching close-up and angled-light pair is still needed."}</p>}
    </section>
    {vinPhoto && <section className="capture-panel"><h2>Confirm the door-jamb VIN</h2>
      <p>Your VIN photo is saved. Any OCR result is a suggestion until you compare it with the physical label and confirm it.</p>
      {currentSuggestion ? <p role="status">Suggested VIN: <strong>{currentSuggestion.suggested_vin ?? "No readable VIN found"}</strong></p> : <button type="button" disabled={working} onClick={recognizeVin}>Read VIN from saved photo</button>}
      <label htmlFor="confirmed-vin">VIN shown on the label</label><input id="confirmed-vin" maxLength={17} autoCapitalize="characters" value={vinInput} onChange={(event) => setVinInput(event.target.value.replace(/[^a-zA-Z0-9]/g, "").toUpperCase())} placeholder="Enter 17 characters" />
      <button type="button" disabled={working || vinInput.length !== 17} onClick={confirmVin}>Confirm this VIN for my vehicle</button>
      {state.vehicle.vin && <p>Saved vehicle VIN: {state.vehicle.vin}</p>}
    </section>}
    {error && <p role="alert">{error}</p>}
    {cameraSteps && !paused && <GuidedCamera steps={cameraSteps} uploaded={cameraSaved} body={bodyStyle} brandName="Estimoto +" photoAccept="image/*" onBodyChange={setBodyStyle}
      checkFrame={checkFrame} onCapture={saveFrame} onClose={() => { setCameraSteps(null); setRetakeKey(null); }} onComplete={finishCamera}
      needsDamagePanel={needsDamagePanel}
      onDamagePanel={(panel) => setCameraSteps([...required, ...hailAreaSteps(panel)])}
      renderAssist={(context) => <CaptureHelp key={context.capture_key} keyName={context.capture_key} rpc={rpc} />}
    />}
  </main>;
}
