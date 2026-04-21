const { withDangerousMod } = require('expo/config-plugins');
const fs = require('fs');
const path = require('path');

module.exports = function withDualCamera(config) {
  return withDangerousMod(config, ['ios', addLocalPodToPodfile]);
};

function addLocalPodToPodfile(config) {
  const podfilePath = path.join(
    config.modRequest.platformProjectRoot,
    'Podfile'
  );
  const srcDir = path.join(__dirname, '..', 'native', 'LocalPods', 'DualCamera');
  const destDir = path.join(
    config.modRequest.platformProjectRoot,
    'LocalPods',
    'DualCamera'
  );

  // Copy all files from native/ to ios/LocalPods/
  if (fs.existsSync(srcDir)) {
    if (!fs.existsSync(destDir)) {
      fs.mkdirSync(destDir, { recursive: true });
    }
    const files = fs.readdirSync(srcDir);
    for (const file of files) {
      const srcFile = path.join(srcDir, file);
      const destFile = path.join(destDir, file);
      fs.copyFileSync(srcFile, destFile);
    }
  }

  // Append pod to Podfile
  if (fs.existsSync(podfilePath)) {
    let podfile = fs.readFileSync(podfilePath, 'utf8');
    const podLine = "  pod 'DualCamera', :path => './LocalPods/DualCamera'";
    if (!podfile.includes("'DualCamera'")) {
      if (podfile.includes('post_install')) {
        podfile = podfile.replace(
          /(\npost_install do \|installer\|)/,
          '\n' + podLine + '\n$1'
        );
      } else {
        const lines = podfile.split('\n');
        const lastEndIdx = lines.map((l, i) => (l.trim() === 'end' ? i : -1)).filter(i => i >= 0).pop() ?? (lines.length - 1);
        lines.splice(lastEndIdx, 0, podLine);
        podfile = lines.join('\n');
      }
      fs.writeFileSync(podfilePath, podfile, 'utf8');
    }
  }

  return config;
}
