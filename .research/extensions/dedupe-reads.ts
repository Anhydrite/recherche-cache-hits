/**
 * dedupe-reads.ts — Prototype A2 : déduplication des relectures de fichiers.
 *
 * Problème mesuré (IDEES-HORS-SENTIER.md, P3) : sur les gros résultats d'outils
 * (>2k chars), 93 % du volume est du contenu BIT-IDENTIQUE relu plusieurs fois
 * (le même fichier lu 175× dans les sessions, parfois via read ET cat).
 *
 * Principe :
 *   - Chaque gros résultat (read ou bash) est hashé (MD5).
 *   - Un store persistant (fichier JSONL par session, passé via DEDUPE_STORE)
 *     mémorise les contenus déjà vus : { hash, size, head (3 premières lignes) }.
 *   - Si un contenu est DÉJÀ connu (hash identique, ou préfixe d'un contenu connu) :
 *     on remplace le résultat par une RÉFÉRENCE courte (<déjà lu — N chars>).
 *     Le contenu complet reste dans l'historique de la session (relu en cache) →
 *     le modèle peut toujours répondre, et on ne re-paie pas le doublon en input.
 *
 * Ne déduplique QUE les gros contenus (> MIN_SIZE) — les petits sont incompressibles.
 * Sûr car le contenu complet est dans les messages précédents de la session.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createHash } from "node:crypto";
import { readFileSync, appendFileSync, existsSync } from "node:fs";

const MIN_SIZE = 2000; // ne traiter que les gros (>2k = ~95 % du volume)
const MAX_STORE = 200; // garder au plus 200 entrées par session

interface Entry {
  hash: string;
  size: number;
  head: string; // 3 premières lignes (rappel pour le modèle)
}

export default function (pi: ExtensionAPI) {
  const storePath =
    process.env.DEDUPE_STORE ??
    "/home/anhydrite/Documents/beta_labo/recherche-cache-hits/.pi-test/results/dedupe-store.jsonl";
  const store = new Map<string, Entry>(); // hash -> entry
  let loaded = false;
  let deduped = 0;
  let savedChars = 0;
  let examined = 0;

  function loadStore() {
    if (loaded) return;
    loaded = true;
    try {
      if (existsSync(storePath)) {
        const lines = readFileSync(storePath, "utf8").split("\n");
        for (const l of lines) {
          if (!l.trim()) continue;
          const e = JSON.parse(l) as Entry;
          if (e.hash) store.set(e.hash, e);
        }
      }
    } catch {}
  }

  function saveEntry(e: Entry) {
    try {
      appendFileSync(storePath, JSON.stringify(e) + "\n");
    } catch {}
  }

  function hashOf(text: string): string {
    return createHash("md5").update(text).digest("hex").slice(0, 12);
  }

  /** Extrait le texte d'un event.content (string | bloc[] | {text}) */
  function extractText(content: any): string {
    if (typeof content === "string") return content;
    if (Array.isArray(content)) {
      return content
        .map((b: any) => (typeof b === "string" ? b : b?.text ?? ""))
        .join("\n");
    }
    if (content && typeof content === "object") return content.text ?? "";
    return "";
  }

  /** Construit la référence de remplacement */
  function buildRef(entry: Entry, partial: boolean): string {
    const kind = partial ? "sous-ensemble" : "déjà lu";
    return (
      `[${kind} — ${entry.size.toLocaleString()} chars (fichier déjà fourni dans cette session)]\n` +
      `Début du contenu (rappel) :\n${entry.head}\n` +
      `[fin de référence — utilise read/cat sur le fichier si tu as besoin du contenu complet]`
    );
  }

  pi.on("tool_result", async (event: any) => {
    try {
      const tool = event?.toolName;
      if (tool !== "read" && tool !== "bash") return;
      const text = extractText(event?.content);
      if (!text || text.length < MIN_SIZE) return;

      loadStore();
      examined++;
      const h = hashOf(text);

      // 1. Hash exact déjà connu → doublon pur
      const known = store.get(h);
      if (known) {
        deduped++;
        savedChars += text.length;
        return { content: buildRef(known, false) };
      }

      // 2. Préfixe d'un contenu connu (lecture partielle d'un fichier déjà lu complet)
      //    On compare avec les entrées stockées : même début ? (échantillon de tête)
      for (const entry of store.values()) {
        if (entry.size > text.length && text.startsWith(entry.head.split("\n")[0] ?? "")) {
          // vérification plus fine : les 200 premiers chars
          if (text.startsWith(entry.head.slice(0, 200))) {
            deduped++;
            savedChars += text.length;
            return { content: buildRef(entry, true) };
          }
        }
      }

      // 3. Nouveau contenu → on le stocke (avec rappel = 3 premières lignes)
      const entry: Entry = {
        hash: h,
        size: text.length,
        head: text.split("\n").slice(0, 3).join("\n").slice(0, 300),
      };
      store.set(h, entry);
      // bornage simple : si trop d'entrées, on vide les plus vieilles (Map insertion order)
      while (store.size > MAX_STORE) {
        const oldest = store.keys().next().value;
        if (oldest === undefined) break;
        store.delete(oldest);
      }
      saveEntry(entry);
    } catch (err) {
      try {
        console.error("[dedupe-reads] erreur:", err);
      } catch {}
    }
  });

  const logStats = () => {
    try {
      console.error(
        `[dedupe-reads] examinés=${examined} dédupliqués=${deduped} chars économisés=${savedChars}`
      );
    } catch {}
  };
  pi.on("session_end", logStats);
  process.on("exit", logStats);
}
