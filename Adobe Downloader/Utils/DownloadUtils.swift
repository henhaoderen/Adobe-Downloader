//
//  Adobe-Downloader
//
//  Created by X1a0He on 2024/10/30.
//
import Foundation
import Network
import Combine
import AppKit

class DownloadUtils {
    typealias ProgressUpdate = (bytesWritten: Int64, totalWritten: Int64, expectedToWrite: Int64)

    private weak var networkManager: NetworkManager?
    private let cancelTracker: CancelTracker

    init(networkManager: NetworkManager, cancelTracker: CancelTracker) {
        self.networkManager = networkManager
        self.cancelTracker = cancelTracker
    }

    private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        var completionHandler: (URL?, URLResponse?, Error?) -> Void
        var progressHandler: ((Int64, Int64, Int64) -> Void)?
        var destinationDirectory: URL
        var fileName: String
        private var hasCompleted = false
        private let completionLock = NSLock()
        
        init(destinationDirectory: URL,
             fileName: String,
             completionHandler: @escaping (URL?, URLResponse?, Error?) -> Void,
             progressHandler: ((Int64, Int64, Int64) -> Void)? = nil) {
            self.destinationDirectory = destinationDirectory
            self.fileName = fileName
            self.completionHandler = completionHandler
            self.progressHandler = progressHandler
            super.init()
        }
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            completionLock.lock()
            defer { completionLock.unlock() }
            
            guard !hasCompleted else { return }
            hasCompleted = true
            
            do {
                if !FileManager.default.fileExists(atPath: destinationDirectory.path) {
                    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                }

                let destinationURL = destinationDirectory.appendingPathComponent(fileName)

                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }

                try FileManager.default.moveItem(at: location, to: destinationURL)
                
                let expectedSize = downloadTask.countOfBytesExpectedToReceive
                if expectedSize > 0,
                   let fileSize = try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64 {
                    print("File size verification - Expected: \(expectedSize), Actual: \(fileSize)")
                    
                    if fileSize != expectedSize {
                        print("Warning: File size mismatch - Expected: \(expectedSize), Actual: \(fileSize)")
                    }
                }
                
                completionHandler(destinationURL, downloadTask.response, nil)
                
            } catch {
                print("File operation error in delegate: \(error.localizedDescription)")
                completionHandler(nil, downloadTask.response, error)
            }
        }
        
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            completionLock.lock()
            defer { completionLock.unlock() }
            
            guard !hasCompleted else { return }
            hasCompleted = true
            
            if let error = error {
                switch (error as NSError).code {
                case NSURLErrorCancelled:
                    return
                case NSURLErrorTimedOut:
                    completionHandler(nil, task.response, NetworkError.downloadError("下载超时", error))
                case NSURLErrorNotConnectedToInternet:
                    completionHandler(nil, task.response, NetworkError.noConnection)
                default:
                    completionHandler(nil, task.response, error)
                }
            }
        }
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, 
                       didWriteData bytesWritten: Int64, 
                       totalBytesWritten: Int64, 
                       totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            guard bytesWritten > 0 else { return }
            
            progressHandler?(bytesWritten, totalBytesWritten, totalBytesExpectedToWrite)
        }
        
        func cleanup() {
            completionHandler = { _, _, _ in }
            progressHandler = nil
        }
    }

    func pauseDownloadTask(taskId: UUID, reason: DownloadStatus.PauseInfo.PauseReason) async {
        if let task = await networkManager?.downloadTasks.first(where: { $0.id == taskId }) {
            task.setStatus(.paused(DownloadStatus.PauseInfo(
                reason: reason,
                timestamp: Date(),
                resumable: true
            )))
            await cancelTracker.pause(taskId)
        }
    }
    
    func resumeDownloadTask(taskId: UUID) async {
        if let task = await networkManager?.downloadTasks.first(where: { $0.id == taskId }) {
            task.setStatus(.downloading(DownloadStatus.DownloadInfo(
                fileName: task.currentPackage?.fullPackageName ?? "",
                currentPackageIndex: 0,
                totalPackages: task.productsToDownload.reduce(0) { $0 + $1.packages.count },
                startTime: Date(),
                estimatedTimeRemaining: nil
            )))
            await startDownloadProcess(task: task)
        }
    }
    
    func cancelDownloadTask(taskId: UUID, removeFiles: Bool = false) async {
        await cancelTracker.cancel(taskId)
        if let task = await networkManager?.downloadTasks.first(where: { $0.id == taskId }) {
            if removeFiles {
                try? FileManager.default.removeItem(at: task.directory)
            }
            task.setStatus(.failed(DownloadStatus.FailureInfo(
                message: "下载已取消",
                error: NetworkError.downloadCancelled,
                timestamp: Date(),
                recoverable: false
            )))
        }
    }
    
    func signApp(at url: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--deep", "--sign", "-", url.path]
        try process.run()
        process.waitUntilExit()
    }
    
    func createInstallerApp(for sapCode: String, version: String, language: String, at destinationURL: URL) throws {
        let parentDirectory = destinationURL.deletingLastPathComponent()
        print(parentDirectory)
        if !FileManager.default.fileExists(atPath: parentDirectory.path) {
            try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")

        let tempScriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("installer.js")
        try NetworkConstants.INSTALL_APP_APPLE_SCRIPT.write(to: tempScriptURL, atomically: true, encoding: .utf8)

        process.arguments = [
            "-l", "JavaScript",
            "-o", destinationURL.path,
            tempScriptURL.path
        ]
        
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw NetworkError.fileSystemError(
                "Failed to create installer app: Exit code \(process.terminationStatus)",
                nil
            )
        }
        
        try? FileManager.default.removeItem(at: tempScriptURL)

        let iconDestination = destinationURL.appendingPathComponent("Contents/Resources/applet.icns")
        if FileManager.default.fileExists(atPath: iconDestination.path) {
            try FileManager.default.removeItem(at: iconDestination)
        }
        
        if FileManager.default.fileExists(atPath: NetworkConstants.ADOBE_CC_MAC_ICON_PATH) {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: NetworkConstants.ADOBE_CC_MAC_ICON_PATH),
                to: iconDestination
            )
        } else {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: NetworkConstants.MAC_VOLUME_ICON_PATH),
                to: iconDestination
            )
        }

        try FileManager.default.createDirectory(
            at: destinationURL.appendingPathComponent("Contents/Resources/products"),
            withIntermediateDirectories: true
        )
    }
    
    func generateDriverXML(sapCode: String, version: String, language: String, productInfo: Sap.Versions, displayName: String) -> String {
        let dependencies = productInfo.dependencies.map { dependency in
            """
                <Dependency>
                    <SAPCode>\(dependency.sapCode)</SAPCode>
                    <BaseVersion>\(dependency.version)</BaseVersion>
                    <EsdDirectory>./\(dependency.sapCode)</EsdDirectory>
                </Dependency>
            """
        }.joined(separator: "\n")
        
        return """
        <DriverInfo>
            <ProductInfo>
                <Name>Adobe \(displayName)</Name>
                <SAPCode>\(sapCode)</SAPCode>
                <CodexVersion>\(version)</CodexVersion>
                <Platform>\(productInfo.apPlatform)</Platform>
                <EsdDirectory>./\(sapCode)</EsdDirectory>
                <Dependencies>
                    \(dependencies)
                </Dependencies>
            </ProductInfo>
            <RequestInfo>
                <InstallDir>/Applications</InstallDir>
                <InstallLanguage>\(language)</InstallLanguage>
            </RequestInfo>
        </DriverInfo>
        """
    }
    
    func clearExtendedAttributes(at url: URL) async throws {
        let escapedPath = url.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        do shell script "sudo xattr -cr '\(escapedPath)'" with administrator privileges
        """
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus != 0 {
                let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
                if let output = String(data: data, encoding: .utf8) {
                    print("xattr command output:", output)
                }
            }
            
            print("Successfully cleared extended attributes for \(url.path)")
        } catch {
            print("Error executing xattr command:", error.localizedDescription)
        }
    }

    internal func startDownloadProcess(task: NewDownloadTask) async {
        actor DownloadProgress {
            var currentPackageIndex: Int = 0
            
            func increment() {
                currentPackageIndex += 1
            }
            
            func get() -> Int {
                return currentPackageIndex
            }
        }
        
        let progress = DownloadProgress()
        
        await MainActor.run {
            let totalPackages = task.productsToDownload.reduce(0) { $0 + $1.packages.count }
            task.setStatus(.downloading(DownloadStatus.DownloadInfo(
                fileName: task.currentPackage?.fullPackageName ?? "",
                currentPackageIndex: 0,
                totalPackages: totalPackages,
                startTime: Date(),
                estimatedTimeRemaining: nil
            )))
            task.objectWillChange.send()
        }

        let driverPath = task.directory.appendingPathComponent("Contents/Resources/products/driver.xml")
        if !FileManager.default.fileExists(atPath: driverPath.path) {
            if let productInfo = await networkManager?.saps[task.sapCode]?.versions[task.version] {
                let driverXml = generateDriverXML(
                    sapCode: task.sapCode,
                    version: task.version,
                    language: task.language,
                    productInfo: productInfo,
                    displayName: task.displayName
                )
                
                do {
                    try driverXml.write(
                        to: driverPath,
                        atomically: true,
                        encoding: .utf8
                    )
                    print("Generated driver.xml successfully")
                } catch {
                    print("Error generating driver.xml:", error.localizedDescription)
                    await MainActor.run {
                        task.setStatus(.failed(DownloadStatus.FailureInfo(
                            message: "生成 driver.xml 失败: \(error.localizedDescription)",
                            error: error,
                            timestamp: Date(),
                            recoverable: false
                        )))
                    }
                    return
                }
            }
        }

        for product in task.productsToDownload {
            for package in product.packages where !package.downloaded {
                let currentIndex = await progress.get()
                
                await MainActor.run {
                    task.currentPackage = package
                    task.setStatus(.downloading(DownloadStatus.DownloadInfo(
                        fileName: package.fullPackageName,
                        currentPackageIndex: currentIndex,
                        totalPackages: task.productsToDownload.reduce(0) { $0 + $1.packages.count },
                        startTime: Date(),
                        estimatedTimeRemaining: nil
                    )))
                }
                
                await progress.increment()
                
                guard !package.fullPackageName.isEmpty,
                      !package.downloadURL.isEmpty,
                      package.downloadSize > 0 else {
                    print("Warning: Skipping invalid package in \(product.sapCode)")
                    continue
                }

                let cdn = await networkManager?.cdn ?? ""
                let cleanCdn = cdn.hasSuffix("/") ? String(cdn.dropLast()) : cdn
                let cleanPath = package.downloadURL.hasPrefix("/") ? package.downloadURL : "/\(package.downloadURL)"
                let downloadURL = cleanCdn + cleanPath
                
                guard let url = URL(string: downloadURL) else {
                    print("Error: Invalid download URL: \(downloadURL)")
                    continue
                }

                do {
                    try await downloadPackage(package: package, task: task, product: product, url: url)
                } catch {
                    print("Error downloading \(package.fullPackageName): \(error.localizedDescription)")
                    await networkManager?.handleError(task.id, error)
                    return
                }
            }
        }

        let allPackagesDownloaded = task.productsToDownload.allSatisfy { product in
            product.packages.allSatisfy { $0.downloaded }
        }
        
        if allPackagesDownloaded {
            await MainActor.run {
                task.setStatus(.completed(DownloadStatus.CompletionInfo(
                    timestamp: Date(),
                    totalTime: Date().timeIntervalSince(task.createAt),
                    totalSize: task.totalSize
                )))
            }
        }
    }

    private func downloadPackage(package: Package, task: NewDownloadTask, product: ProductsToDownload, url: URL) async throws {
        var lastUpdateTime = Date()
        var lastBytes: Int64 = 0
        
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(
                destinationDirectory: task.directory.appendingPathComponent("Contents/Resources/products/\(product.sapCode)"),
                fileName: package.fullPackageName,
                completionHandler: { [weak networkManager] localURL, response, error in
                    if let error = error {
                        if (error as NSError).code == NSURLErrorCancelled {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: error)
                        }
                        return
                    }

                    Task { @MainActor in
                        package.downloadedSize = package.downloadSize
                        package.progress = 1.0
                        package.status = .completed
                        package.downloaded = true

                        print("\nPackage completed: \(package.fullPackageName)")
                        print("Package size: \(package.downloadSize)")
                        print("Package downloaded size: \(package.downloadedSize)")
                        print("Package status: \(package.status)")

                        var totalDownloaded: Int64 = 0
                        var totalSize: Int64 = 0

                        for prod in task.productsToDownload {
                            print("\nProduct: \(prod.sapCode)")
                            for pkg in prod.packages {
                                totalSize += pkg.downloadSize
                                if pkg.downloaded {
                                    totalDownloaded += pkg.downloadSize
                                    print("- \(pkg.fullPackageName): \(pkg.downloadSize) (completed)")
                                } else {
                                    print("- \(pkg.fullPackageName): \(pkg.downloadSize) (pending)")
                                }
                            }
                        }

                        print("\nProgress Summary:")
                        print("Total downloaded: \(totalDownloaded)")
                        print("Total size: \(totalSize)")

                        task.totalSize = totalSize
                        task.totalDownloadedSize = totalDownloaded
                        task.totalProgress = Double(totalDownloaded) / Double(totalSize)
                        task.totalSpeed = 0

                        let allCompleted = task.productsToDownload.allSatisfy { product in
                            product.packages.allSatisfy { $0.downloaded }
                        }

                        print("All packages completed: \(allCompleted)")

                        if allCompleted {
                            task.setStatus(.completed(DownloadStatus.CompletionInfo(
                                timestamp: Date(),
                                totalTime: Date().timeIntervalSince(task.createAt),
                                totalSize: totalSize
                            )))
                            print("Task marked as completed")
                        }

                        task.objectWillChange.send()
                        networkManager?.objectWillChange.send()
                    }

                    continuation.resume()
                },
                progressHandler: { [weak networkManager] bytesWritten, totalBytesWritten, totalBytesExpectedToWrite in
                    Task { @MainActor in
                        let now = Date()
                        let timeDiff = now.timeIntervalSince(lastUpdateTime)

                        if timeDiff >= 1.0 {
                            let bytesDiff = totalBytesWritten - lastBytes
                            let speed = Double(bytesDiff) / timeDiff
                            
                            package.updateProgress(
                                downloadedSize: totalBytesWritten,
                                speed: speed
                            )
                            
                            var completedSize: Int64 = 0
                            var totalSize: Int64 = 0
                            
                            for prod in task.productsToDownload {
                                for pkg in prod.packages {
                                    totalSize += pkg.downloadSize
                                    if pkg.downloaded {
                                        completedSize += pkg.downloadSize
                                    } else if pkg.id == package.id {
                                        completedSize += totalBytesWritten
                                    }
                                }
                            }
                            
                            task.totalSize = totalSize
                            task.totalDownloadedSize = completedSize
                            task.totalProgress = Double(completedSize) / Double(totalSize)
                            task.totalSpeed = speed
                            
                            lastUpdateTime = now
                            lastBytes = totalBytesWritten
                            
                            task.objectWillChange.send()
                            networkManager?.objectWillChange.send()
                        }
                    }
                }
            )
            
            var request = URLRequest(url: url)
            NetworkConstants.downloadHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

            Task {
                if let resumeData = await cancelTracker.getResumeData(task.id) {
                    let downloadTask = session.downloadTask(withResumeData: resumeData)
                    await cancelTracker.registerTask(task.id, task: downloadTask, session: session)
                    await cancelTracker.clearResumeData(task.id)
                    downloadTask.resume()
                } else {
                    let downloadTask = session.downloadTask(with: request)
                    await cancelTracker.registerTask(task.id, task: downloadTask, session: session)
                    downloadTask.resume()
                }
            }
        }
    }

    func retryPackage(task: NewDownloadTask, package: Package) async throws {
        guard package.canRetry else { return }
        
        package.prepareForRetry()

        if let product = task.productsToDownload.first(where: { $0.packages.contains(where: { $0.id == package.id }) }) {
            await MainActor.run {
                task.currentPackage = package
            }

            if let cdn = await networkManager?.cdnUrl {
                try await downloadPackage(package: package, task: task, product: product, url: URL(string: cdn + package.downloadURL)!)
            } else {
                throw NetworkError.invalidData("无法获取 CDN 地址")
            }
        }
    }
}
