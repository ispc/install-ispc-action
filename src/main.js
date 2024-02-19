// SPDX-License-Identifier: Apache-2.0

import * as core from '@actions/core';
import * as path from "path";


function validatePlatform(platform) {
    let platformList = [
        'linux',
        'macOS',
        'windows'
    ];
    if(!platformList.includes(platform)) {
        throw new Error(`Platform ${platform} not in list of supported platforms: ${platformList}`);
    }
    return platform;
}


function validateArch(platform, arch) {
    let archMap = {
        "linux" : [
            "oneapi",
            "aarch64"
        ],
        "macOS" : [
            "x86_64",
            "arm64",
            "universal"
        ]
    };
    let defaultArch = {
        "macOS" : "universal"
    };
    if(!arch) {
        if(platform in defaultArch) {
            arch = defaultArch[platform];
        }
        else {
            return;
        }
    }
    if(!archMap[platform] || !archMap[platform].includes(arch)) {
        throw new Error(`Platform ${platform} does not support arch ${arch}`);
    }
    return arch;
}

async function getIspc(version, platform, architecture) {
    // TODO: Implement retry!
    let versionStr = `v${version}`;
    let archPrefix = architecture === 'oneapi' ? '-' : '.';
    let archStr = architecture ? `${archPrefix}${architecture}` : "";
    let extension = platform === "windows" ? ".zip" : ".tar.gz";
    let url = `https://github.com/ispc/ispc/releases/download/${versionStr}/ispc-${versionStr}-${platform}${archStr}${extension}`;
    let outFile = `ispc-${versionStr}-${platform}${archStr}${extension}`;
    await extractFile(await getFileTo(url, outFile));
    if(architecture === 'oneapi') {
        // oneapi just gets extracted to ispc-<version>-<platform>
        archStr = '';
    }
    let binDir = `ispc-${versionStr}-${platform}${archStr}/bin`;
    return path.resolve(binDir);
}

async function getLatestVersion() {
    let response = await fetch(`https://api.github.com/repos/ispc/ispc/releases/latest`);
    if(response.status !== 200) {
        throw new Error (`Unable to query latest version`);
    }
    let body = await response.json();
    let version = body.tag_name;
    if(version.charAt(0) === 'v') {
        version = version.substring(1);
    }
    return version;
}

(async function() {
    try {
        let version = core.getInput('version');
        if(!version || version === 'latest') {
            version = await getLatestVersion();
        }
        let platform = validatePlatform(core.getInput('platform', {required: true}));
        let architecture = validateArch(platform, core.getInput('architecture'));
        let exe = platform === "windows" ? ".exe" : "";
        let ispcBinDir = await getIspc(version, platform, architecture);
        let ispcExe = path.resolve(`${ispcBinDir}/ispc${exe}`);
        let res = await exec(`${ispcExe} --version`);
        if(res.exitCode === 0) {
            let match = res.output.match(/([0-9]+)\.([0-9]+)\.([0-9]+)/);
            let matchVer = match[0];
            if(matchVer === version) {
                console.log(`ISPC (${version}) Installation Success`);
            }
            else {
                throw new Error(`Unable to match ispc version ${version} with ${matchVer}`);
            }
        }
        else {
            throw new Error(`Unable to run ispc at ${ispcExe}`);
        }
        core.addPath(ispcBinDir);
    } catch(error) {
        core.setFailed(error.message)
    }
})();
