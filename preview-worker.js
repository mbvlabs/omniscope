#!/usr/bin/env node
const fs = require("fs")
const path = require("path")
const { execFile, spawn } = require("child_process")
const Preview = require("./PreviewModel.js")

const target = process.argv[2] || ""
const batTheme = process.argv[3] === "light" ? "GitHub" : "Visual Studio Dark+"
const MAX_FILE_BYTES = 4 * 1024 * 1024
const MAX_IMAGE_BYTES = 32 * 1024 * 1024
const MAX_READ_BYTES = 128 * 1024
const MAX_MIME_BYTES = 8192
const MAX_LINES = 400
const OPEN_FLAGS = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0)

function sizeText(bytes) {
  if (bytes < 1024) return bytes + " B"
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KiB"
  return (bytes / (1024 * 1024)).toFixed(1) + " MiB"
}

function output(value) { process.stdout.write(JSON.stringify(value)) }

function closeFd(fd, callback) {
  fs.close(fd, callback || function() {})
}

function openVerified(targetPath, callback) {
  fs.open(targetPath, OPEN_FLAGS, function(openError, fd) {
    if (openError) return callback(openError)
    fs.fstat(fd, function(statError, stat) {
      if (statError) {
        closeFd(fd)
        return callback(statError)
      }
      callback(null, fd, stat)
    })
  })
}

function readFd(fd, offset, length, callback) {
  const buffer = Buffer.alloc(length)
  fs.read(fd, buffer, 0, length, offset, function(readError, bytesRead) {
    if (readError) return callback(readError)
    callback(null, buffer.subarray(0, bytesRead))
  })
}

function mimeTypeFromSample(sample, callback) {
  const child = spawn("file", ["--brief", "--mime-type", "-"])
  let stdout = ""
  child.stdout.on("data", function(chunk) { stdout += chunk })
  child.on("error", function() { callback("application/octet-stream") })
  child.on("close", function(code) {
    callback(code === 0 && stdout.trim() ? stdout.trim() : "application/octet-stream")
  })
  child.stdin.end(sample)
}

function highlightedText(base, fileName, fallback, truncated) {
  execFile("bat", [
    "--color=always",
    "--style=plain",
    "--paging=never",
    "--wrap=never",
    "--line-range", ":" + MAX_LINES,
    "--theme", batTheme,
    "--file-name", fileName,
    "-"
  ], { input: fallback, timeout: 3000, maxBuffer: MAX_READ_BYTES * 8 }, function(error, stdout) {
    if (error) {
      output({ ...base, state: "text", content: fallback, truncated: truncated, rich: false })
      return
    }
    output({ ...base, state: "text", content: Preview.ansiToHtml(stdout), truncated: truncated, rich: true })
  })
}

function previewImage(fd, stat, base, mime) {
  readFd(fd, 0, stat.size, function(readError, sample) {
    closeFd(fd)
    if (readError) {
      output({ ...base, state: "error", message: "Image read failed: " + readError.message })
      return
    }
    output({
      ...base,
      state: "image",
      imageData: "data:" + mime + ";base64," + sample.toString("base64")
    })
  })
}

function previewText(sample, stat, base) {
  const bounded = Preview.boundedText(sample, MAX_LINES)
  const cut = bounded.truncated || stat.size > sample.length
  if (path.extname(target).toLowerCase() === ".desktop") {
    const summary = Preview.desktopSummary(Preview.parseDesktopEntry(bounded.text))
    output({ ...base, state: "desktop", content: summary || bounded.text, truncated: cut })
  } else {
    highlightedText(base, path.basename(target), bounded.text, cut)
  }
}

if (!target) {
  output({ state: "error", mime: "Unknown", size: "Unknown", message: "No file path provided." })
  process.exit(0)
}

openVerified(target, function(openError, fd, stat) {
  if (openError) {
    const code = openError.code
    let message = "File cannot be read."
    if (code === "ENOENT") message = "File no longer exists."
    else if (code === "ELOOP") message = "Preview does not follow symbolic links."
    else if (openError.message) message = "File cannot be read: " + openError.message
    output({ state: "error", mime: "Unknown", size: "Unknown", message: message })
    return
  }
  if (!stat.isFile()) {
    closeFd(fd)
    output({ state: "unsupported", mime: "inode/other", size: sizeText(stat.size), message: "Preview is only available for regular files." })
    return
  }

  const sniffLength = Math.min(stat.size, MAX_MIME_BYTES)
  readFd(fd, 0, sniffLength, function(sniffError, sniff) {
    if (sniffError) {
      closeFd(fd)
      output({ state: "error", mime: "Unknown", size: sizeText(stat.size), message: "Preview read failed: " + sniffError.message })
      return
    }

    mimeTypeFromSample(sniff, function(mime) {
      const base = { mime: mime || "application/octet-stream", size: sizeText(stat.size), bytes: stat.size }
      const isImage = /^image\/(png|jpeg|gif|webp|bmp|x-icon|svg\+xml|tiff)$/.test(base.mime)
      if (isImage) {
        if (stat.size > MAX_IMAGE_BYTES) {
          closeFd(fd)
          output({ ...base, state: "unsupported", message: "Image is too large to preview safely." })
          return
        }
        if (stat.size <= sniff.length) {
          closeFd(fd)
          output({
            ...base,
            state: "image",
            imageData: "data:" + base.mime + ";base64," + sniff.toString("base64")
          })
          return
        }
        previewImage(fd, stat, base, base.mime)
        return
      }

      if (stat.size > MAX_FILE_BYTES) {
        closeFd(fd)
        output({ ...base, state: "unsupported", message: "File is too large for a bounded content preview." })
        return
      }

      const textLength = Math.min(stat.size, MAX_READ_BYTES)
      if (textLength <= sniff.length) {
        closeFd(fd)
        if (Preview.looksBinary(sniff)) {
          output({ ...base, state: "unsupported", message: "Binary content is not previewed." })
          return
        }
        previewText(sniff, stat, base)
        return
      }

      readFd(fd, 0, textLength, function(readError, sample) {
        closeFd(fd)
        if (readError) {
          output({ ...base, state: "error", message: "Preview read failed: " + readError.message })
          return
        }
        if (Preview.looksBinary(sample)) {
          output({ ...base, state: "unsupported", message: "Binary content is not previewed." })
          return
        }
        previewText(sample, stat, base)
      })
    })
  })
})
