#!/usr/bin/env python3
"""Contrôles du workflow nixelec qui ne se voient ni au YAML ni à l'éval.

Deux classes d'erreur ont coûté un run CI complet chacune, parce qu'elles ne
se manifestent qu'à l'exécution :

1. **Syntaxe shell des blocs `run: |`.** Un commentaire inséré entre deux lignes
   terminées par un backslash coupe la commande en deux : la suite devient une
   commande inconnue (exit 127). Le YAML, lui, reste parfaitement valide.

2. **Cohérence build / push.** Un chemin calculé par `nix path-info` n'est pas
   réalisé par cette commande — elle imprime. Si la cible correspondante n'est
   pas dans le `nix build` du même job, `cachix push` échoue en « path ... is
   not valid » APRÈS la compilation complète.

Usage :
    ./scripts/check-ci-workflow.py [chemin/vers/ci.yml]

Sortie : code 0 si tout passe, 1 sinon. À lancer avant tout commit qui touche
le workflow.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

DEFAUT = Path(__file__).resolve().parent.parent / ".github/workflows/ci.yml"

# Un chemin poussé peut être légitime sans figurer dans le `nix build` du job
# quand il est un **sous-produit** d'une cible construite : construire l'image
# SD réalise la fermeture complète du système, donc son toplevel. Un contrôle
# statique ne peut pas le déduire, et l'ignorer en silence rendrait le contrôle
# inutile — d'où cette table, volontairement explicite et nominative.
EXCEPTIONS = {
    ("image", "toplevel"): "toplevel compris dans la fermeture de l'image construite",
}


def blocs_run(lines: list[str]) -> list[tuple[int, str]]:
    """Extrait chaque bloc `run: |` avec son numéro de ligne de départ."""
    blocs: list[tuple[int, str]] = []
    i = 0
    while i < len(lines):
        m = re.match(r"^(\s*)(?:- )?run: \|$", lines[i])
        if not m:
            i += 1
            continue
        indent = len(m.group(1)) + 2
        j = i + 1
        corps: list[str] = []
        while j < len(lines):
            ligne = lines[j]
            if not ligne.strip():
                corps.append("")
            elif len(ligne) - len(ligne.lstrip()) >= indent:
                corps.append(ligne[indent:])
            else:
                break
            j += 1
        blocs.append((i + 1, "\n".join(corps)))
        i = j
    return blocs


def verifie_shell(lines: list[str]) -> list[str]:
    erreurs = []
    blocs = blocs_run(lines)
    for numero, corps in blocs:
        r = subprocess.run(["bash", "-n"], input=corps, text=True, capture_output=True)
        if r.returncode != 0:
            detail = r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "?"
            erreurs.append(f"ligne {numero}: syntaxe shell -> {detail[:100]}")
    print(f"blocs run: | : {len(blocs)} verifies")
    return erreurs


def verifie_coherence(texte: str) -> list[str]:
    """Chaque chemin poussé par un job doit être construit par ce même job."""
    erreurs = []
    # découpage grossier par job de premier niveau (indentation de deux espaces)
    jobs = re.split(r"\n  (?=[a-z][\w-]*:\n)", texte)
    total = 0
    for job in jobs:
        if "nix path-info" not in job or "nix build" not in job:
            continue
        nom = re.search(r"^\s*(?:name: )?(\S+)", job, re.M)
        etiquette = (nom.group(1) if nom else "?").rstrip(":")
        # les lignes `nix path-info` mentionnent la cible sans la construire :
        # les exclure, sinon le controle ne peut jamais echouer.
        lignes_build = "\n".join(
            l for l in job.splitlines() if "nix path-info" not in l
        )
        build = set(re.findall(r"\.#([A-Za-z0-9_][A-Za-z0-9_./-]*)", lignes_build))
        # toutes les affectations `x=$(nix path-info ... .#cible)`
        affectations = re.findall(r"(\w+)=\$\(nix path-info[^)]*?\.#(\S+?)\)", job)
        if not affectations:
            continue
        total += len(affectations)
        for variable, cible in affectations:
            if cible in build:
                continue
            if (etiquette, variable) in EXCEPTIONS:
                print(f"  (exception) {etiquette}/{variable}: {EXCEPTIONS[(etiquette, variable)]}")
                continue
            erreurs.append(
                f"job {etiquette}: {variable} pousse .#{cible} "
                "qui n'est pas dans le `nix build` du job"
            )
    print(f"coherence build/push : {total} chemins inspectes")
    return erreurs


def main() -> int:
    chemin = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAUT
    if not chemin.is_file():
        print(f"introuvable : {chemin}", file=sys.stderr)
        return 2
    texte = chemin.read_text()
    lines = texte.splitlines()

    erreurs = verifie_shell(lines) + verifie_coherence(texte)
    if erreurs:
        print()
        for e in erreurs:
            print(f"  ECHEC  {e}")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
