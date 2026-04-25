const { withDangerousMod } = require('expo/config-plugins');
const fs = require('fs');
const path = require('path');

const POD_NAME = 'DualCamera';
const POD_LINE = `  pod '${POD_NAME}', :path => './LocalPods/${POD_NAME}'`;

module.exports = function withDualCamera(config) {
  return withDangerousMod(config, ['ios', copyNativeAndPatchPodfile]);
};

module.exports.__internal = {
  copyNativeAndPatchPodfile,
  patchPodfile,
};

function copyNativeAndPatchPodfile(config) {
  const projectRoot = config.modRequest.projectRoot;
  const podfilePath = path.join(projectRoot, 'ios', 'Podfile');
  const srcDir = path.join(projectRoot, 'native', 'LocalPods', POD_NAME);
  const destDir = path.join(projectRoot, 'ios', 'LocalPods', POD_NAME);

  if (!fs.existsSync(srcDir)) {
    throw new Error(`[withDualCamera] Missing native sources: ${srcDir}`);
  }

  if (!fs.existsSync(podfilePath)) {
    throw new Error(`[withDualCamera] Missing generated Podfile: ${podfilePath}`);
  }

  fs.rmSync(destDir, { recursive: true, force: true });
  copyRecursiveSync(srcDir, destDir);

  const podfile = fs.readFileSync(podfilePath, 'utf8');
  const patchedPodfile = patchPodfile(podfile);
  if (patchedPodfile !== podfile) {
    fs.writeFileSync(podfilePath, patchedPodfile, 'utf8');
  }

  return config;
}

function copyRecursiveSync(srcDir, destDir) {
  fs.mkdirSync(destDir, { recursive: true });

  for (const entry of fs.readdirSync(srcDir, { withFileTypes: true })) {
    const srcPath = path.join(srcDir, entry.name);
    const destPath = path.join(destDir, entry.name);

    if (entry.isDirectory()) {
      copyRecursiveSync(srcPath, destPath);
    } else if (entry.isFile()) {
      fs.copyFileSync(srcPath, destPath);
    }
  }
}

function patchPodfile(podfile) {
  if (podfile.includes(`pod '${POD_NAME}'`)) {
    return podfile;
  }

  const newline = podfile.includes('\r\n') ? '\r\n' : '\n';
  const lines = podfile.split(/\r?\n/);
  const targetStart = lines.findIndex((line) => /^\s*target\s+['"][^'"]+['"]\s+do\s*$/.test(line));

  if (targetStart === -1) {
    throw new Error(`[withDualCamera] Could not find an iOS target block in Podfile`);
  }

  const targetEnd = findMatchingEnd(lines, targetStart);
  if (targetEnd === -1) {
    throw new Error(`[withDualCamera] Could not find the end of the iOS target block in Podfile`);
  }

  const useExpoModulesIndex = findLineInRange(lines, targetStart + 1, targetEnd, /^\s*use_expo_modules!(?:\s|\(|$)/);
  const postInstallIndex = findLineInRange(lines, targetStart + 1, targetEnd, /^\s*post_install\s+do\b/);
  const insertAt = useExpoModulesIndex !== -1
    ? useExpoModulesIndex + 1
    : (postInstallIndex !== -1 ? postInstallIndex : targetEnd);

  lines.splice(insertAt, 0, POD_LINE);
  return lines.join(newline);
}

function findLineInRange(lines, start, end, pattern) {
  for (let i = start; i < end; i += 1) {
    if (pattern.test(lines[i])) {
      return i;
    }
  }
  return -1;
}

function findMatchingEnd(lines, startIndex) {
  let depth = 0;

  for (let i = startIndex; i < lines.length; i += 1) {
    const code = lines[i].replace(/#.*/, '').trim();
    if (!code) {
      continue;
    }

    if (opensRubyBlock(code)) {
      depth += 1;
    }

    if (/^end\s*$/.test(code)) {
      depth -= 1;
      if (depth === 0) {
        return i;
      }
    }
  }

  return -1;
}

function opensRubyBlock(code) {
  return /^(target|abstract_target|post_install|pre_install)\b.*\bdo\b/.test(code)
    || /^(if|unless|case|begin|class|module|def|for|while|until)\b/.test(code)
    || /\bdo\s*(\|.*\|)?\s*$/.test(code);
}
