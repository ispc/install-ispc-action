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
                reject(new Error(`Unexpected response: ${res.statusCode}`));
            }
            res.on('data', (data) => {
                file.write(data);
            });
            res.on('end', () => {
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
        proc.stderr.pipe(process.stderr);
        proc.stdout.pipe(process.stdout);
        proc.on('exit', resolve);
        proc.on('error', reject);
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

async function getIspc(version, platform) {
    // TODO: Implement retry!
    version = `v${version}`;
    let extension = platform === "windows" ? ".zip" : ".tar.gz";
    let url = `https://github.com/ispc/ispc/releases/download/${version}/ispc-${version}-${platform}${extension}`;
    let outFile = `ispc-${version}-${platform}${extension}`;
    await extractFile(await getFileTo(url, outFile));
    let binDir = `ispc-${version}-${platform}/bin`;
    return binDir
}

(async function() {
    try {
        let version = core.getInput('version', {required: true});
        let platform = core.getInput('platform', {required: true});
        let exe = platform === "windows" ? ".exe" : "";
        let ispcBinDir = await getIspc(version, platform);
        await exec(`${ispcBinDir}/ispc${exe} --version`);
        core.addPath(ispcBinDir);
    } catch(error) {
        core.setFailed(error.message)
    }
})();