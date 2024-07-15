// SPDX-License-Identifier: Apache-2.0

import { resolve } from 'path'
import { downloadTool, extractTar, extractZip } from '@actions/tool-cache'
import { addPath, setFailed, getInput } from '@actions/core'
import { platform as osPlatform, arch as osArch } from 'node:os'
import { existsSync, rmSync } from 'node:fs'
import { execSync } from 'node:child_process'

async function getLatestVersion () {
  // Note: The GitHub API is rate limited to 60 requests per hour for unauthenticated users.
  // I am not quite sure that it is reliable to query the latest version from
  // the GitHub API because of the rate limits.
  let version
  const response = await fetch('https://api.github.com/repos/ispc/ispc/releases/latest')
  if (response.status !== 200) {
    const errorDetails = await response.text()
    console.log(`Unable to query latest version: ${response.statusText} - ${errorDetails}`)

    try {
      // Fallback to local git repository
      const repoPath = 'ispc-repo'
      if (!existsSync(repoPath)) {
        execSync(`git clone --depth=1 https://github.com/ispc/ispc.git ${repoPath}`)
      }

      console.log('Fetching latest tags from the repository...')
      execSync(`git -C ${repoPath} fetch --tags`)

      const latestTagSHA = execSync(`git -C ${repoPath} rev-list --tags --max-count=1`).toString().trim()
      version = execSync(`git -C ${repoPath} describe --tags ${latestTagSHA}`).toString().trim()

      rmSync(repoPath, { recursive: true, force: true })
    } catch (gitError) {
      throw new Error(`Unable to get latest version from git repository: ${gitError.message}`)
    }
  } else {
    const body = await response.json()
    version = body.tag_name
  }

  if (version.charAt(0) === 'v') {
    version = version.substring(1)
  }
  console.log(`Latest ISPC version is '${version}'`)
  return version
}

function validateVersion (version) {
  const versionRegex = /^[0-9]+\.[0-9]+\.[0-9]+$/
  if (!version.match(versionRegex)) {
    throw new Error(`Invalid version ${version}`)
  }
}

async function getVersion () {
  let version = getInput('version')
  if (!version || version === 'latest') {
    version = await getLatestVersion()
  }
  validateVersion(version)
  const versionStr = `v${version}`
  return versionStr
}

function validatePlatform (platform) {
  const platformList = [
    'linux',
    'macOS',
    'windows'
  ]
  if (!platformList.includes(platform)) {
    throw new Error(`Platform ${platform} not in list of supported platforms: ${platformList}`)
  }
}

function getPlatform () {
  let platform = getInput('platform')
  if (!platform) {
    const p = osPlatform()
    switch (p) {
      case 'linux':
        platform = 'linux'
        break
      case 'darwin':
        platform = 'macOS'
        break
      case 'win32':
        platform = 'windows'
        break
      default:
        throw new Error(`Platform ${p} is unsupported for autodetection`)
    }
    console.log(`Autodetected platform: '${platform}'`)
  }
  validatePlatform(platform)
  return platform
}

function validateArch (platform, arch) {
  const archMap = {
    linux: [
      'oneapi',
      'aarch64',
      ''
    ],
    macOS: [
      'x86_64',
      'arm64',
      'universal'
    ],
    windows: [
      ''
    ]
  }
  if (!archMap[platform] || !archMap[platform].includes(arch)) {
    throw new Error(`Platform ${platform} does not support arch ${arch}`)
  }
}

function getArch (platform) {
  let arch = getInput('architecture')
  if (!arch) {
    const a = osArch()
    switch (platform) {
      case 'linux':
        switch (a) {
          case 'arm64':
            arch = 'aarch64'
            break
          case 'x64':
            // ISPC doesn't have arch suffix for x86_64 linux archives
            arch = ''
            break
          default:
            throw new Error(`Architecture ${a} is unsupported for autodetection`)
        }
        break
      case 'macOS':
        arch = 'universal'
        break
      case 'windows':
        // ISPC has only x86_64 windows archives
        arch = ''
        break
    }
    console.log(`Autodetected architecture '${arch}'`)
  }
  if (arch === 'x86_64' && (platform === 'linux' || platform === 'windows')) {
    // ISPC doesn't have arch suffix for x86_64 linux and windows archives
    arch = ''
  }
  validateArch(platform, arch)
  return arch
}

async function getIspc (version, platform, architecture) {
  const archPrefix = architecture === 'oneapi' ? '-' : '.'
  const archStr = architecture ? `${archPrefix}${architecture}` : ''
  const extension = platform === 'windows' ? '.zip' : '.tar.gz'
  const archiveName = `ispc-${version}-${platform}${archStr}`
  const url = `https://github.com/ispc/ispc/releases/download/${version}/${archiveName}${extension}`
  const dir = 'ispc-releases'
  console.log(`Downloading ISPC archive ${url}`)
  const archive = await downloadTool(url)
  if (extension === '.zip') {
    await extractZip(archive, dir)
  } else {
    await extractTar(archive, dir)
  }
  const binDir = resolve(dir, archiveName, 'bin')
  return binDir
}

(async function () {
  try {
    // ISPC release naming convention: ispc-${version}-${platform}[.|-]${architecture}.[zip|tar.gz]
    const version = await getVersion()
    const platform = getPlatform()
    const architecture = getArch(platform)
    const ispcBinDir = await getIspc(version, platform, architecture)
    console.log(`Adding ISPC binary directory to PATH: ${ispcBinDir}`)
    addPath(ispcBinDir)
  } catch (error) {
    setFailed(error.message)
  }
})()
