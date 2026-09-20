import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import "@testing-library/jest-dom/vitest";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { CaptureApp } from "./CaptureApp";
import { RPCError, type CaptureRPC } from "./rpc";

vi.mock("./shared/VehicleGuide", () => ({ BODY_STYLES: ["sedan"], bodyLabel: () => "Sedan", bodyStyleFor: () => "sedan", VehicleGuide: () => <div>3D target</div> }));

const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=";
const hash = "6b1048f8a6d40bac0b2954c18fefa40c4ea7a96120fc2e54b7317c0e43c2bbec";
const createUrl = vi.fn(() => "blob:private-preview");
const revokeUrl = vi.fn();
beforeEach(() => {
  createUrl.mockClear(); revokeUrl.mockClear();
  vi.stubGlobal("URL", class extends URL { static createObjectURL = createUrl; static revokeObjectURL = revokeUrl; });
});
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

function fixture(complete = false) {
  const labels = complete ? ["odometer", "vin", "engine_bay", "interior", "tire_tread", "front", "driver", "rear", "passenger"] : ["vin"];
  const state = { estimate_id: "draft", discipline: "collision", vehicle: { year: 2020, make: "Example", model: "Car", vin: "" },
    photos: labels.map((label) => ({ id: `photo-${label}`, label, sha256: hash as string | null, quality: "not_checked" })), vin_suggestion: null };
  const request = vi.fn(async (method: string, params: Record<string, unknown>): Promise<unknown> => {
    if (method === "captureState") return state;
    if (method === "readSavedPhoto") return { id: params.photo_id, sha256: params.photo_sha256, mime_type: "image/png", base64: png };
    throw new Error(`Unexpected ${method}`);
  });
  return { state, request, api: { request, ready: vi.fn(), close: vi.fn() } as unknown as Pick<CaptureRPC, "request" | "ready" | "close"> };
}

it("reviews a completed required walk without reopening the camera and fetches only the selected saved photo", async () => {
  const fake = fixture(true);
  render(<CaptureApp rpc={fake.api} />);
  fireEvent.click(await screen.findByRole("button", { name: "Review required photos" }));
  expect(await screen.findByRole("img", { name: "Odometer photo" })).toHaveAttribute("src", "blob:private-preview");
  expect(screen.queryByRole("dialog", { name: "Guided vehicle camera" })).not.toBeInTheDocument();
  expect(fake.request.mock.calls.filter(([method]) => method === "readSavedPhoto")).toEqual([
    ["readSavedPhoto", { photo_id: "photo-odometer", photo_sha256: hash }, 25_000],
  ]);
  fireEvent.change(screen.getByRole("combobox", { name: "Saved photo" }), { target: { value: "photo-vin" } });
  expect(await screen.findByRole("img", { name: "VIN at driver’s door jamb" })).toBeVisible();
  expect(revokeUrl).toHaveBeenCalledWith("blob:private-preview");
  expect(screen.getByText("Framing was not checked for this photo.")).toBeVisible();
});

it("opens a saved required photo before the walk is complete and permits retaking only that step", async () => {
  const fake = fixture();
  render(<CaptureApp rpc={fake.api} />);
  fireEvent.click(await screen.findByRole("button", { name: "Review VIN at driver’s door jamb" }));
  await screen.findByRole("img", { name: "VIN at driver’s door jamb" });
  fireEvent.click(screen.getByRole("button", { name: "Retake this photo" }));
  expect(await screen.findByRole("heading", { name: "VIN at driver’s door jamb" })).toBeVisible();
  expect(screen.getByLabelText("Upload photo for current view")).toBeEnabled();
  expect(screen.queryByRole("heading", { name: "Photos saved" })).not.toBeInTheDocument();
  expect(fake.state.photos[0].id).toBe("photo-vin");
  expect(screen.queryByRole("img")).not.toBeInTheDocument();
});

it("offers retry for old hosts or failed reads without losing saved evidence", async () => {
  const fake = fixture();
  fake.request.mockImplementation(async (method, params) => {
    if (method === "captureState") return fake.state;
    if (method === "readSavedPhoto") throw new RPCError("This capture action is unavailable.", 422);
    throw new Error(String(params));
  });
  render(<CaptureApp rpc={fake.api} />);
  fireEvent.click(await screen.findByRole("button", { name: "Review VIN at driver’s door jamb" }));
  expect(await screen.findByRole("alert")).toHaveTextContent("Your photo is still saved");
  expect(screen.queryByRole("img")).not.toBeInTheDocument();
  fake.request.mockImplementation(async (method, params) => method === "captureState" ? fake.state :
    { id: params.photo_id, sha256: params.photo_sha256, mime_type: "image/png", base64: png });
  fireEvent.click(screen.getByRole("button", { name: "Retry loading photo" }));
  expect(await screen.findByRole("img", { name: "VIN at driver’s door jamb" })).toBeVisible();
});

it("sends older photos without verification hashes back to estimate review instead of retrying an impossible read", async () => {
  const fake = fixture();
  fake.state.photos[0].sha256 = null;
  fake.request.mockImplementation(async (method) => method === "captureState" ? fake.state : {});
  render(<CaptureApp rpc={fake.api} />);
  fireEvent.click(await screen.findByRole("button", { name: "Review VIN at driver’s door jamb" }));
  expect(await screen.findByText("This older photo is saved. View it from your estimate, or retake it to enable review here.")).toBeVisible();
  expect(screen.queryByRole("button", { name: "Retry loading photo" })).not.toBeInTheDocument();
  expect(fake.request.mock.calls.some(([method]) => method === "readSavedPhoto")).toBe(false);
  fireEvent.click(screen.getByRole("button", { name: "Return to estimate" }));
  expect(fake.request).toHaveBeenLastCalledWith("close");
});

it("discards loaded and late private photo bytes when capture pauses", async () => {
  const fake = fixture();
  render(<CaptureApp rpc={fake.api} />);
  fireEvent.click(await screen.findByRole("button", { name: "Review VIN at driver’s door jamb" }));
  await screen.findByRole("img");
  act(() => window.dispatchEvent(new Event("capture:pause")));
  expect(screen.queryByRole("img")).not.toBeInTheDocument();
  expect(revokeUrl).toHaveBeenCalledWith("blob:private-preview");
  act(() => window.dispatchEvent(new Event("capture:resume")));
  await waitFor(() => expect(screen.getByRole("button", { name: "Review VIN at driver’s door jamb" })).toBeEnabled());
  let resolve!: (value: unknown) => void;
  fake.request.mockImplementation(async (method) => method === "captureState" ? fake.state : new Promise((yes) => { resolve = yes; }));
  fireEvent.click(screen.getByRole("button", { name: "Review VIN at driver’s door jamb" }));
  act(() => window.dispatchEvent(new Event("capture:pause")));
  await act(async () => resolve({ id: "photo-vin", sha256: hash, mime_type: "image/png", base64: png }));
  expect(screen.queryByRole("img")).not.toBeInTheDocument();
  expect(createUrl).toHaveBeenCalledTimes(1);
});

it.each([
  { id: "foreign", sha256: hash, mime_type: "image/png", base64: png },
  { id: "photo-vin", sha256: "b".repeat(64), mime_type: "image/png", base64: png },
  { id: "photo-vin", sha256: hash, mime_type: "image/svg+xml", base64: "PHN2Zy8+" },
  { id: "photo-vin", sha256: hash, mime_type: "image/png", base64: "https://unsafe.example.test" },
])("refuses a mismatched or unsafe host preview without exposing an image ($id $mime_type)", async (result) => {
  const fake = fixture();
  fake.request.mockImplementation(async (method) => method === "captureState" ? fake.state : result);
  render(<CaptureApp rpc={fake.api} />);
  fireEvent.click(await screen.findByRole("button", { name: "Review VIN at driver’s door jamb" }));
  await screen.findByRole("alert");
  expect(createUrl).not.toHaveBeenCalled();
  expect(screen.queryByRole("img")).not.toBeInTheDocument();
});

it("retakes a saved photo through the existing save flow and then reviews the replacement", async () => {
  const fake = fixture();
  fake.request.mockImplementation(async (method, params) => {
    if (method === "captureState") return fake.state;
    if (method === "saveCapture") {
      expect(params.capture_key).toBe("vin");
      expect(params.photo).toEqual({ base64: png, mime_type: "image/png" });
      fake.state.photos[0] = { ...fake.state.photos[0], sha256: "b".repeat(64) };
      return fake.state.photos[0];
    }
    if (method === "readSavedPhoto") return { id: params.photo_id, sha256: params.photo_sha256, mime_type: "image/png", base64: png };
    throw new Error(`Unexpected ${method}`);
  });
  render(<CaptureApp rpc={fake.api} />);
  fireEvent.click(await screen.findByRole("button", { name: "Review VIN at driver’s door jamb" }));
  await screen.findByRole("img");
  fireEvent.click(screen.getByRole("button", { name: "Retake this photo" }));
  const picker = await screen.findByLabelText("Upload photo for current view");
  const file = new File([Uint8Array.from(atob(png), (c) => c.charCodeAt(0))], "replacement.png", { type: "image/png" });
  fireEvent.change(picker, { target: { files: [file] } });
  expect(await screen.findByRole("img", { name: "VIN at driver’s door jamb" })).toBeVisible();
  expect(fake.request).toHaveBeenLastCalledWith("readSavedPhoto", { photo_id: "photo-vin", photo_sha256: "b".repeat(64) }, 25_000);
});
