// SPDX-License-Identifier: Apache-2.0

import * as core from '@actions/core';
import * as fs from "fs/promises";
import * as https from "https";
import * as path from "path";
import * as child_process from "child_process";

async function getFileTo(url, outFile) {
    let file = await fs.open(outFile, 'w');
    let getFn = url => (resolve, reject) => {
        let req = https.get(url, (res) => {
            if(res.statusCode == 301 || res.statusCode == 302) {
                // Follow redirects.
                getFn(res.headers.location)(resolve, reject)
                return;
            }
            if(res.statusCode !== 200) {
                reject(new Error(`Unexpected response: ${res.statusCode} at ${url}`));
            }
            let datas = [];
            res.on('data', (data) => {
                // It seems that it's possible for these to resolve out of order on certain platforms if we just write them here.
                datas.push(data);
            });
            res.on('end', async () => {
                for(let data of datas) {
                    await file.write(data);
                }
                file.close();
                resolve();
            });
        });
        req.on('error', reject);
    };
    await new Promise(getFn(url));
    return outFile;
}

function exec(command) {
    return new Promise((resolve, reject) => {
        let proc = child_process.exec(command);
        let output = "";
        proc.stderr.pipe(process.stderr);
        proc.stdout.pipe(process.stdout);
        proc.stdout.on('data', (chunk) => {
            output += chunk;
        });
        proc.on('exit', () => {
            resolve({
                exitCode: proc.exitCode,
                output: output
            });
        });
        proc.on('error', () => {
            reject({
                exitCode: -1,
                output: output
            });
        });
    });
}

async function extractFile(file) {
    // Assumes unzip and tar is installed.
    let ext = path.extname(file);
    if(ext === ".zip") {
        // Might need to use powershell Extract-Archive on Windows?
        await exec(`unzip ${file}`);
    }
    else if(ext === ".gz") {
        await exec(`tar xvf ${file}`);
    }
    else {
        throw new Error(`Unexpected file extension ${ext}`);
    }
    return file;
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