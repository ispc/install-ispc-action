// SPDX-License-Identifier: Apache-2.0

import { resolve } from "path";
import { downloadTool, extractTar, extractZip } from '@actions/tool-cache';
import { addPath, setFailed, getInput } from '@actions/core';
import { platform as osPlatform, arch as osArch } from 'node:os';


async function getLatestVersion() {
    // Note: The GitHub API is rate limited to 60 requests per hour for unauthenticated users.
    // I am not quite sure that it is reliable to query the latest version from
    // the GitHub API because of the rate limits.
    let response = await fetch(`https://api.github.com/repos/ispc/ispc/releases/latest`);
    if(response.status !== 200) {
        let errorDetails = await response.text();
        throw new Error (`Unable to query latest version: ${response.statusText} - ${errorDetails}`);
    }
    let body = await response.json();
    let version = body.tag_name;
    if(version.charAt(0) === 'v') {
        version = version.substring(1);
    }
    console.log(`Latest ISPC version is '${version}'`);
    return version;
}

function validateVersion(version) {
    let versionRegex = /^[0-9]+\.[0-9]+\.[0-9]+$/;
    if(!version.match(versionRegex)) {
        throw new Error(`Invalid version ${version}`);
    }
}

async function getVersion() {
    let version = getInput('version');
    if(!version || version === 'latest') {
        version = await getLatestVersion();
    }
    validateVersion(version);
    let versionStr = `v${version}`;
    return versionStr;
}

function validatePlatform(platform) {
    let platformList = [
        'linux',
        'macOS',
        'windows'
    ];
    if(!platformList.includes(platform)) {
        throw new Error(`Platform ${platform} not in list of supported platforms: ${platformList}`);
    }
}

function getPlatform() {
    let platform = getInput('platform');
    if(!platform) {
        const p = osPlatform();
        switch(p) {
            case 'linux':
                platform = 'linux';
                break;
            case 'darwin':
                platform = 'macOS';
                break;
            case 'win32':
                platform = 'windows';
                break;
            default:
                throw new Error(`Platform ${p} is unsupported for autodetection`);
        }
        console.log(`Autodetected platform: '${platform}'`);
    }
    validatePlatform(platform);
    return platform;
}

function validateArch(platform, arch) {
    let archMap = {
        "linux" : [
            "oneapi",
            "aarch64",
            "",
        ],
        "macOS" : [
            "x86_64",
            "arm64",
            "universal",
        ],
        "windows" : [
            "",
        ]
    };
    if(!archMap[platform] || !archMap[platform].includes(arch)) {
        throw new Error(`Platform ${platform} does not support arch ${arch}`);
    }
}

function getArch(platform) {
    let arch = getInput('architecture');
    if(!arch) {
        const a = osArch();
        switch(platform) {
            case 'linux':
                switch(a) {
                    case 'arm64':
                        arch = 'aarch64';
                        break;
                    case 'x64':
                        // ISPC doesn't have arch suffix for x86_64 linux archives
                        arch = '';
                        break;
                    default:
                        throw new Error(`Architecture ${a} is unsupported for autodetection`);
                }
                break;
            case 'macOS':
                arch = 'universal';
                break;
            case 'windows':
                // ISPC has only x86_64 windows archives
                arch = '';
                break;
        }
        console.log(`Autodetected architecture '${arch}'`);
    }
    if(arch === 'x86_64' && (platform === 'linux' || platform === 'windows')) {
        // ISPC doesn't have arch suffix for x86_64 linux and windows archives
        arch = '';
    }
    validateArch(platform, arch);
    return arch;
}

async function getIspc(version, platform, architecture) {
    let archPrefix = architecture === 'oneapi' ? '-' : '.';
    let archStr = architecture ? `${archPrefix}${architecture}` : "";
    let extension = platform === "windows" ? ".zip" : ".tar.gz";
    let archive_name = `ispc-${version}-${platform}${archStr}`;
    let url = `https://github.com/ispc/ispc/releases/download/${version}/${archive_name}${extension}`;
    let dir = `ispc-releases`;
    console.log(`Downloading ISPC archive ${url}`);
    const archive = await downloadTool(url);
    if(extension === ".zip") {
        await extractZip(archive, dir);
    } else {
        await extractTar(archive, dir);
    }
    let binDir = resolve(dir, archive_name, "bin");
    return binDir;
}

(async function() {
    try {
        // ISPC release naming convention: ispc-${version}-${platform}[.|-]${architecture}.[zip|tar.gz]
        let version = await getVersion();
        let platform = getPlatform();
        let architecture = getArch(platform);
        let ispcBinDir = await getIspc(version, platform, architecture);
        console.log(`Adding ISPC binary directory to PATH: ${ispcBinDir}`);
        addPath(ispcBinDir);
    } catch(error) {
        setFailed(error.message)
    }
})();
