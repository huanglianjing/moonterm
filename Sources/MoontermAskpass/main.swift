// MoontermAskpass —— ssh 的 SSH_ASKPASS 助手。
//
// ssh 需要密码时会执行本程序，argv[1] 是提示语，程序把答案打到 stdout。
// 密码本体放在临时文件里（0600），路径由环境变量 MOONTERM_SECRET_FILE 传进来。
//
// 只回答密码/passphrase 类提问。其他提问（例如首次连接的 yes/no 主机密钥确认）
// 一律以退出码 1 拒绝，让 ssh 自己走原来的路径 —— 绝不把密码交给来路不明的提示。

import Foundation

let secretFileEnvKey = "MOONTERM_SECRET_FILE"

let prompt = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let lowered = prompt.lowercased()

let isPasswordPrompt = lowered.contains("password") || lowered.contains("passphrase")
guard isPasswordPrompt else {
    FileHandle.standardError.write(Data("moonterm-askpass: 不处理该提示：\(prompt)\n".utf8))
    exit(1)
}

guard let path = ProcessInfo.processInfo.environment[secretFileEnvKey] else {
    FileHandle.standardError.write(Data("moonterm-askpass: 缺少 \(secretFileEnvKey)\n".utf8))
    exit(1)
}

guard let data = FileManager.default.contents(atPath: path) else {
    FileHandle.standardError.write(Data("moonterm-askpass: 读不到密码文件\n".utf8))
    exit(1)
}

// 文件里是不带换行的原始密码；ssh 期望读到一行，所以补一个换行。
var out = data
out.append(0x0A)
FileHandle.standardOutput.write(out)
exit(0)
