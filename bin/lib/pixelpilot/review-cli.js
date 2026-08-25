#!/usr/bin/env node

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const { writeRawDiffMaskArtifact } = require('./diff-artifacts');
const { renderReviewHtml } = require('./review-html');

function printUsage() {
  console.log(`
Usage: pixelpilot [options]

Options:
  --current-dir <path>   Directory containing the current build (default: current working directory)
  --baseline-dir <path>  Directory containing the baseline build (default: extracted from git)
  --output-html <path>   Path to write the review HTML file (default: review.html)
  --manifest <path>      Path to the manifest file (default: generated automatically)
  --baseline <ref>       Git ref to use as baseline (default: HEAD)
  --help                 Show this help message
`);
}

function parseArgs(argv) {
  const options = {
    baseline: 'HEAD'
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];

    switch (arg) {
      case '--current-dir':
        options.currentDir = next;
        index += 1;
        break;
      case '--baseline-dir':
        options.baselineDir = next;
        index += 1;
        break;
      case '--output-html':
        options.outputHtml = next;
        index += 1;
        break;
      case '--manifest':
        options.manifest = next;
        index += 1;
        break;
      case '--baseline':
        options.baseline = next;
        index += 1;
        break;
      case '--help':
        printUsage();
        process.exit(0);
      default:
        throw new Error(`Unknown option: ${arg}`);
    }
  }

  return applyDefaults(options);
}

function applyDefaults(options) {
  const resolved = { ...options };

  if (!resolved.currentDir) {
    resolved.currentDir = path.join('tmp', 'screenshot-output');
  }
  if (!resolved.baselineDir) {
    resolved.baselineDir = path.join('doc', 'screenshots');
  }
  if (!resolved.outputHtml) {
    resolved.outputHtml = path.join('tmp', 'screenshot-review', 'index.html');
  }

  return resolved;
}

function validateGitRef(ref) {
  try {
    execFileSync('git', ['cat-file', '-t', ref], { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });
  } catch {
    throw new Error(`Invalid git reference: ${ref}`);
  }
}

function extractBaselineFromGit(ref, outputDir) {
  let screenshotFiles;
  try {
    const output = execFileSync('git', ['ls-tree', '-r', '--name-only', ref, 'doc/screenshots'], {
      encoding: 'utf8',
      maxBuffer: 10 * 1024 * 1024,
      stdio: ['pipe', 'pipe', 'pipe']
    });
    screenshotFiles = output
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line.endsWith('.png'));
  } catch {
    screenshotFiles = [];
  }

  fs.mkdirSync(outputDir, { recursive: true });

  screenshotFiles.forEach((filePath) => {
    const fileName = path.basename(filePath);
    const outputPath = path.join(outputDir, fileName);

    try {
      const content = execFileSync('git', ['show', `${ref}:${filePath}`], {
        encoding: null,
        maxBuffer: 50 * 1024 * 1024,
        stdio: ['pipe', 'pipe', 'pipe']
      });
      fs.writeFileSync(outputPath, content);
    } catch (error) {
      throw new Error(`Failed to extract ${filePath} from ${ref}: ${error.message}`);
    }
  });
}

function gitDescribe(ref) {
  return execFileSync('git', ['describe', '--long', ref], { encoding: 'utf8' }).trim();
}

function isoTimestamp() {
  return new Date().toISOString();
}

function pngFiles(dir) {
  return fs.readdirSync(dir).filter((file) => file.endsWith('.png')).sort();
}

function buildManifest(options) {
  if (options.manifest) {
    return JSON.parse(fs.readFileSync(options.manifest, 'utf8'));
  }

  const baselineRef = options.baseline;
  validateGitRef(baselineRef);
  extractBaselineFromGit(baselineRef, options.baselineDir);

  const baselineDescribe = gitDescribe(baselineRef);
  const currentDescribe = gitDescribe('HEAD');
  const generatedAt = isoTimestamp();
  const diffOutputDir = path.join(path.dirname(options.outputHtml), 'diffs');
  const scenarios = pngFiles(options.currentDir).map((file) => ({
    file,
    baseline_path: relativeAssetPath(options.outputHtml, path.join(options.baselineDir, file)),
    current_path: relativeAssetPath(options.outputHtml, path.join(options.currentDir, file)),
    diff_path: relativeAssetPath(
      options.outputHtml,
      buildDiffArtifact({
        currentDir: options.currentDir,
        baselineDir: options.baselineDir,
        diffOutputDir,
        file
      }) || path.join(options.currentDir, file)
    )
  }));

  return {
    baseline: {
      ref: baselineRef,
      describe: baselineDescribe,
      generated_at: generatedAt
    },
    current: {
      describe: currentDescribe,
      generated_at: generatedAt
    },
    scenarios
  };
}

function buildDiffArtifact({ currentDir, baselineDir, diffOutputDir, file }) {
  const currentPath = path.join(currentDir, file);
  const baselinePath = path.join(baselineDir, file);

  if (!fs.existsSync(currentPath) || !fs.existsSync(baselinePath)) {
    return null;
  }

  return writeRawDiffMaskArtifact({
    currentBuffer: fs.readFileSync(currentPath),
    baselineBuffer: fs.readFileSync(baselinePath),
    outputDir: diffOutputDir,
    artifactName: file
  });
}

function relativeAssetPath(outputHtml, assetPath) {
  return path.relative(path.dirname(outputHtml), assetPath);
}

function bundledScriptSource() {
  const reviewPagePath = path.join(__dirname, 'review-page.js');
  return fs.readFileSync(reviewPagePath, 'utf8');
}

function printStartSummary(options) {
  process.stdout.write(
    [
      'Generating screenshot review page with:',
      `  baseline: ${options.baseline}`,
      `  current-dir: ${options.currentDir}`,
      `  baseline-dir: ${options.baselineDir}`,
      `  output-html: ${options.outputHtml}`,
      options.manifest ? `  manifest: ${options.manifest}` : null
    ].filter(Boolean).join('\n') + '\n'
  );
}

function writeReview(options) {
  printStartSummary(options);
  const manifest = buildManifest(options);
  const html = renderReviewHtml({ manifest, scriptSource: bundledScriptSource() });
  fs.mkdirSync(path.dirname(options.outputHtml), { recursive: true });
  fs.writeFileSync(options.outputHtml, html);
  process.stdout.write(`Wrote screenshot review page to ${options.outputHtml}\n`);
  return options.outputHtml;
}

function openInBrowser(filePath) {
  const { execSync } = require('node:child_process');
  const isWin = process.platform === 'win32';
  const isMac = process.platform === 'darwin';
  const isLinux = process.platform === 'linux';

  let cmd;
  if (isMac) {
    cmd = `open "${filePath}"`;
  } else if (isWin) {
    cmd = `start "" "${filePath}"`;
  } else if (isLinux) {
    cmd = `xdg-open "${filePath}"`;
  } else {
    return false;
  }

  try {
    execSync(cmd, { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

function promptForOpen(filePath) {
  return new Promise((resolve) => {
    const countdownSeconds = 5;
    let secondsLeft = countdownSeconds;

    if (process.stdin.isTTY) {
      process.stdin.setRawMode(true);
    }
    process.stdin.resume();
    process.stdin.setEncoding('utf8');

    const printStatus = () => {
      process.stdout.write(`\rDone. press 'o' to open in browser (${secondsLeft}s) `);
    };

    printStatus();

    const interval = setInterval(() => {
      secondsLeft -= 1;
      if (secondsLeft < 0) {
        clearInterval(interval);
        process.stdin.pause();
        if (process.stdin.isTTY) {
          process.stdin.setRawMode(false);
        }
        process.stdout.write('\n');
        const relativePath = path.relative(process.cwd(), filePath);
        process.stdout.write(`\nopen ${relativePath}\n`);
        resolve(false);
        return;
      }
      printStatus();
    }, 1000);

    const keyHandler = (char) => {
      if (char === 'o' || char === 'O') {
        clearInterval(interval);
        process.stdin.removeListener('data', keyHandler);
        process.stdin.pause();
        if (process.stdin.isTTY) {
          process.stdin.setRawMode(false);
        }
        process.stdout.write('\n');
        resolve(true);
      } else if (char === '' || char === '') {
        clearInterval(interval);
        process.stdin.removeListener('data', keyHandler);
        process.stdin.pause();
        if (process.stdin.isTTY) {
          process.stdin.setRawMode(false);
        }
        process.stdout.write('\n');
        const relativePath = path.relative(process.cwd(), filePath);
        process.stdout.write(`\nopen ${relativePath}\n`);
        resolve(false);
      }
    };

    process.stdin.on('data', keyHandler);
  });
}

function main() {
  try {
    const options = parseArgs(process.argv.slice(2));
    const htmlPath = writeReview(options);

    if (!process.stdin.isTTY) {
      const relativePath = path.relative(process.cwd(), htmlPath);
      process.stdout.write(`\nopen ${relativePath}\n`);
      process.exit(0);
    }

    promptForOpen(htmlPath).then((shouldOpen) => {
      if (shouldOpen) {
        openInBrowser(htmlPath);
      }
      process.exit(0);
    });
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(1);
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  applyDefaults,
  buildDiffArtifact,
  buildManifest,
  extractBaselineFromGit,
  main,
  openInBrowser,
  parseArgs,
  promptForOpen,
  validateGitRef,
  writeReview
};
