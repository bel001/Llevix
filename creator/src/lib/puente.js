// Puente entre la interfaz y la app.
// Dentro de la app (Tauri) usa los comandos reales. En un navegador común y SOLO en modo
// desarrollo (npm run dev) usa una simulación con datos de ejemplo, para poder ver y
// ajustar el diseño sin compilar la app ni tocar discos.
import { invoke as invokeTauri } from "@tauri-apps/api/core";
import { listen as listenTauri } from "@tauri-apps/api/event";
import { open as openTauri } from "@tauri-apps/plugin-dialog";

const enTauri = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
const simular = !enTauri && import.meta.env.DEV;
const simulacion = () => import("./simulacion.js");

export const invoke = (...a) => (simular ? simulacion().then((m) => m.invoke(...a)) : invokeTauri(...a));
export const listen = (...a) => (simular ? simulacion().then((m) => m.listen(...a)) : listenTauri(...a));
export const elegirArchivo = (...a) => (simular ? simulacion().then((m) => m.open(...a)) : openTauri(...a));
export const esSimulacion = simular;
