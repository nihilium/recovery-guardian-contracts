/**
 * Extracts the ABI surface from the Forge build artifacts into `abi.generated.ts`.
 *
 *     forge build && node bindings/generate-abi.mjs
 *
 * This is the artifact-only boundary. The SDK imports the generated file and nothing else — never
 * Solidity source, never a typechain graph over it — so the contract toolchain and the TypeScript
 * toolchain stay independent of each other. `@nihilium/registry` does the same thing by requiring
 * `out/*.json` directly; generating a committed .ts file instead keeps `out/` (which is gitignored
 * and large) out of the published package.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, "..", "out");

const CONTRACTS = [
    { file: "RecoveryModule.sol", name: "RecoveryModule", export: "recoveryModuleAbi" },
    { file: "GradualVeto.sol", name: "GradualVeto", export: "gradualVetoAbi" },
];

const parts = CONTRACTS.map(({ file, name, export: exportName }) => {
    const artifactPath = join(out, file, `${name}.json`);
    let artifact;
    try {
        artifact = JSON.parse(readFileSync(artifactPath, "utf8"));
    } catch (cause) {
        throw new Error(
            `Missing Forge artifact ${artifactPath}. Run \`forge build\` before this script.`,
            { cause },
        );
    }
    return `/** ABI of \`${name}\`, from the Forge build artifact. */\nexport const ${exportName} = ${
        JSON.stringify(artifact.abi, null, 4)
    } as const;\n`;
});

const banner = `/**
 * GENERATED FILE — do not edit.
 *
 * Produced by \`bindings/generate-abi.mjs\` from the Forge build in \`out/\`. Regenerate with
 * \`npm run build:sol && npm run build:abi\` in this package.
 */
`;

writeFileSync(join(here, "abi.generated.ts"), `${banner}\n${parts.join("\n")}`);
process.stdout.write(`Wrote abi.generated.ts for ${CONTRACTS.map((c) => c.name).join(", ")}\n`);
