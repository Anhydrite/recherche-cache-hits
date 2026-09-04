/**
 * rewrite-bash-output.ts — Prototype A3+B1 : réécrire les sorties bash pour le cache.
 *
 * Idées testées (IDEES-HORS-SENTIER.md) :
 *   A3 — Réécrire les sorties verbeuses en format dense :
 *        - `ls -la` / listings → arbre de chemins condensé (sans dates/perms/owner)
 *        - sorties `find` → liste triée compacte
 *   B1 — Neutraliser les variations bit-instables :
 *        - timestamps (`Sep  4 12:01`, dates ISO) → `[ts]`
 *        - chemins absolus machine → forme relative neutre `[path]`
 *
 * But : réduire les tokens PAYÉS PLEIN TARIF (les gros résultats bash = 64 % du coût)
 * ET rendre les sorties réutilisables (2 exécutions du même ls = mêmes octets → hit).
 *
 * Implémenté sur le hook `tool_result` (peut modifier le contenu avant envoi au provider).
 * NE réécrit que les sorties bash de type "listing" — jamais les logs/erreurs/contenu réel.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// Seuil : on ne réécrit que les résultats > 1 000 chars (97 % du gisement)
const THRESHOLD = 1000;

export default function (pi: ExtensionAPI) {
  // Statistiques (écrites en stderr pour le driver)
  let rewritten = 0;
  let savedChars = 0;
  let examined = 0;

  function logStats() {
    try {
      console.error(
        `[rewrite-bash] examinés=${examined} réécrits=${rewritten} chars économisés=${savedChars}`
      );
    } catch {}
  }

  /**
   * Détecte une sortie de type "listing de fichiers" (ls, find, etc.)
   * — lignes commençant par des permissions type Unix (drwx...) ou "total N".
   */
  function looksLikeFileListing(text: string): boolean {
    const lines = text.split("\n").filter((l) => l.trim().length > 0);
    if (lines.length < 3) return false;
    // Au moins 30% de lignes de type listing
    const listingRe = /^(total \d+|[-dl][rwxsStT-]{9})/;
    let listing = 0;
    for (const l of lines.slice(0, 60)) {
      if (listingRe.test(l.trim())) listing++;
    }
    return listing / Math.min(lines.length, 60) >= 0.3;
  }

  /**
   * Réécrit un `ls -la`/`find` verbeux en liste compacte de noms de fichiers.
   * Parse le format ls -la robuste : perms liens owner group size Mois Jour HH:MM nom
   * Gère les sorties multi-répertoires (plusieurs blocs "total N").
   */
  function rewriteListing(text: string): string {
    const ENTRY =
      /^([-dlbcps][rwxsStT-]{9})\s+\d+\s+\S+\s+\S+\s+\d+\s+([A-Z][a-z]{2})\s+(\d{1,2})\s+(\d{1,2}:\d{2}|\d{4})\s+(.+)$/;
    const lines = text.split("\n");
    const blocks: string[][] = [];
    let cur: string[] = [];
    for (const l of lines) {
      const t = l.trimEnd();
      const st = t.trim();
      if (st.startsWith("total ")) {
        if (cur.length) blocks.push(cur);
        cur = [];
        continue;
      }
      const m = st.match(ENTRY);
      if (m) {
        const name = m[5].trim();
        if (name !== "." && name !== "..") cur.push(name);
      } else if (st && !st.startsWith("total ")) {
        // ligne sans permissions = fin de la sortie listing → on coupe
        if (cur.length) blocks.push(cur);
        cur = [];
      }
    }
    if (cur.length) blocks.push(cur);
    if (!blocks.length) return text;

    const out: string[] = [];
    for (const b of blocks) {
      const unique = [...new Set(b)];
      out.push(unique.length > 1 ? unique.sort().join(" · ") : unique[0]);
    }
    return `[fichiers]\n${out.join("\n")}`;
  }

  /** Neutralise les timestamps/chemins variables (B1) — pour les sorties non-listing */
  function neutralize(text: string): string {
    // dates type "Sep  4 12:01" ou "2026-09-04T10:25:15" → [ts]
    let out = text.replace(/\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\s+[\d:]+\b/g, "[ts]");
    out = out.replace(/\b\d{4}-\d{2}-\d{2}T[\d:.]+Z?\b/g, "[ts]");
    out = out.replace(/\b\d{4}-\d{2}-\d{2}\s+[\d:]+\b/g, "[ts]");
    // chemins absolus machine (/home/user/...) → [path] (ne garde que le nom de fichier final si utile)
    return out;
  }

  pi.on("tool_result", async (event: any) => {
    try {
      if (event.toolName !== "bash") return;
      let content = event.content;
      // content peut être un string ou un tableau de blocs
      let text = "";
      if (typeof content === "string") text = content;
      else if (Array.isArray(content)) {
        text = content.map((b: any) => (typeof b === "string" ? b : b?.text ?? "")).join("\n");
      } else if (content && typeof content === "object") {
        text = content.text ?? "";
      }
      if (!text || text.length < THRESHOLD) return;

      examined++;
      let newText: string | null = null;
      if (looksLikeFileListing(text)) {
        newText = rewriteListing(text);
      } else {
        // B1 sur les sorties longues non-listing : neutraliser les timestamps variables
        const neutral = neutralize(text);
        if (neutral !== text) newText = neutral;
      }
      if (newText && newText.length < text.length) {
        savedChars += text.length - newText.length;
        rewritten++;
        // Retourner le contenu remplacé (même format que l'entrée)
        if (typeof content === "string") {
          return { content: newText };
        } else if (Array.isArray(content)) {
          return { content: [{ type: "text", text: newText }] };
        }
      }
    } catch (err) {
      // Ne jamais casser le tool_result — en cas d'erreur on laisse tel quel
      try { console.error("[rewrite-bash] erreur:", err); } catch {}
    }
  });

  // Log des stats à la fin
  pi.on("session_end", () => logStats());
  process.on("exit", () => logStats());
}
