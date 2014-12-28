//
//  Project.swift
//  Carthage
//
//  Created by Alan Rogers on 12/10/2014.
//  Copyright (c) 2014 Carthage. All rights reserved.
//

import Foundation
import LlamaKit
import ReactiveCocoa

/// Carthage’s bundle identifier.
public let CarthageKitBundleIdentifier = NSBundle(forClass: Project.self).bundleIdentifier!

// TODO: remove this once we’ve bumped LlamaKit.
private func try<T>(f: NSErrorPointer -> T?) -> Result<T> {
	var error: NSError?
	let because = -1
	return f(&error).map(success) ?? failure(error ?? NSError(domain: CarthageKitBundleIdentifier, code: because, userInfo: nil))
}

/// ~/Library/Caches/org.carthage.CarthageKit/
private let CarthageUserCachesURL: NSURL = {
	let URL = try { error in
		NSFileManager.defaultManager().URLForDirectory(NSSearchPathDirectory.CachesDirectory, inDomain: NSSearchPathDomainMask.UserDomainMask, appropriateForURL: nil, create: true, error: error)
	}

	let fallbackDependenciesURL = NSURL.fileURLWithPath("~/.carthage".stringByExpandingTildeInPath, isDirectory:true)!

	switch URL {
	case .Success:
		NSFileManager.defaultManager().removeItemAtURL(fallbackDependenciesURL, error: nil)

	case let .Failure(error):
		NSLog("Warning: No Caches directory could be found or created: \(error.localizedDescription). (\(error))")
	}

	return URL.value()?.URLByAppendingPathComponent(CarthageKitBundleIdentifier, isDirectory: true) ?? fallbackDependenciesURL
}()

/// The file URL to the directory in which downloaded release binaries will be
/// stored.
///
/// ~/Library/Caches/org.carthage.CarthageKit/binaries/
public let CarthageDependencyAssetsURL = CarthageUserCachesURL.URLByAppendingPathComponent("binaries", isDirectory: true)

/// The file URL to the directory in which cloned dependencies will be stored.
///
/// ~/Library/Caches/org.carthage.CarthageKit/dependencies/
public let CarthageDependencyRepositoriesURL = CarthageUserCachesURL.URLByAppendingPathComponent("dependencies", isDirectory: true)

/// The relative path to a project's Cartfile.
public let CarthageProjectCartfilePath = "Cartfile"

/// The relative path to a project's Cartfile.private.
public let CarthageProjectPrivateCartfilePath = "Cartfile.private"

/// The relative path to a project's Cartfile.resolved.
public let CarthageProjectResolvedCartfilePath = "Cartfile.resolved"

/// The text that needs to exist in a GitHub Release asset's name, for it to be
/// tried as a binary framework.
public let CarthageProjectBinaryAssetPattern = ".framework"

/// MIME types allowed for GitHub Release assets, for them to be considered as
/// binary frameworks.
public let CarthageProjectBinaryAssetContentTypes = [
	"application/zip"
]

/// Describes an event occurring to or with a project.
public enum ProjectEvent {
	/// The project is beginning to clone.
	case Cloning(ProjectIdentifier)

	/// The project is beginning a fetch.
	case Fetching(ProjectIdentifier)

	/// The project is being checked out to the specified revision.
	case CheckingOut(ProjectIdentifier, String)

	/// Any available binaries for the specified release of the project are
	/// being downloaded. This may still be followed by `CheckingOut` event if
	/// there weren't any viable binaries after all.
	case DownloadingBinaries(ProjectIdentifier, String)
}

/// Represents a project that is using Carthage.
public final class Project {
	/// File URL to the root directory of the project.
	public let directoryURL: NSURL

	/// The project's Cartfile.
	public let cartfile: Cartfile

	/// The file URL to the project's Cartfile.resolved.
	public var resolvedCartfileURL: NSURL {
		return directoryURL.URLByAppendingPathComponent(CarthageProjectResolvedCartfilePath, isDirectory: false)
	}

	/// Whether to prefer HTTPS for cloning (vs. SSH).
	public var preferHTTPS = true

	/// Whether to use submodules for dependencies, or just check out their
	/// working directories.
	public var useSubmodules = false

	/// Sends each event that occurs to a project underneath the receiver (or
	/// the receiver itself).
	public let projectEvents: HotSignal<ProjectEvent>
	private let _projectEventsSink: SinkOf<ProjectEvent>

	public required init(directoryURL: NSURL, cartfile: Cartfile) {
		let (signal, sink) = HotSignal<ProjectEvent>.pipe()
		projectEvents = signal
		_projectEventsSink = sink

		self.directoryURL = directoryURL

		// TODO: Load this lazily.
		self.cartfile = cartfile
	}

	/// Caches versions to avoid expensive lookups, and unnecessary
	/// fetching/cloning.
	private var cachedVersions: [ProjectIdentifier: [PinnedVersion]] = [:]
	private let cachedVersionsScheduler = QueueScheduler()

	/// Reads the current value of `cachedVersions` on the appropriate
	/// scheduler.
	private func readCachedVersions() -> ColdSignal<[ProjectIdentifier: [PinnedVersion]]> {
		return ColdSignal.lazy {
				return .single(self.cachedVersions)
			}
			.evaluateOn(cachedVersionsScheduler)
			.deliverOn(QueueScheduler())
	}

	/// Adds a given version to `cachedVersions` on the appropriate scheduler.
	private func addCachedVersion(version: PinnedVersion, forProject project: ProjectIdentifier) {
		self.cachedVersionsScheduler.schedule {
			if var versions = self.cachedVersions[project] {
				versions.append(version)
				self.cachedVersions[project] = versions
			} else {
				self.cachedVersions[project] = [ version ]
			}
		}
	}

	/// Attempts to load project information from the given directory.
	public class func loadFromDirectory(directoryURL: NSURL) -> Result<Project> {
		precondition(directoryURL.fileURL)

		let cartfileURL = directoryURL.URLByAppendingPathComponent(CarthageProjectCartfilePath, isDirectory: false)
		let privateCartfileURL = directoryURL.URLByAppendingPathComponent(CarthageProjectPrivateCartfilePath, isDirectory: false)

		// TODO: Load this lazily.
		var error: NSError?
		if let cartfileContents = NSString(contentsOfURL: cartfileURL, encoding: NSUTF8StringEncoding, error: &error) {
			return Cartfile.fromString(cartfileContents).flatMap { (var cartfile) in
				if let privateCartfileContents = NSString(contentsOfURL: privateCartfileURL, encoding: NSUTF8StringEncoding, error: nil) {
					switch Cartfile.fromString(privateCartfileContents) {
					case let .Success(privateCartfile):
						cartfile.appendCartfile(privateCartfile.unbox)

					case let .Failure(error):
						return failure(error)
					}
				}

				return success(self(directoryURL: directoryURL, cartfile: cartfile))
			}
		} else {
			return failure(error ?? CarthageError.ReadFailed(cartfileURL).error)
		}
	}

	/// Reads the project's Cartfile.resolved.
	public func readResolvedCartfile() -> Result<ResolvedCartfile> {
		var error: NSError?
		let resolvedCartfileContents = NSString(contentsOfURL: resolvedCartfileURL, encoding: NSUTF8StringEncoding, error: &error)
		if let resolvedCartfileContents = resolvedCartfileContents {
			return ResolvedCartfile.fromString(resolvedCartfileContents)
		} else {
			return failure(error ?? CarthageError.ReadFailed(resolvedCartfileURL).error)
		}
	}

	/// Writes the given Cartfile.resolved out to the project's directory.
	public func writeResolvedCartfile(resolvedCartfile: ResolvedCartfile) -> Result<()> {
		var error: NSError?
		if resolvedCartfile.description.writeToURL(resolvedCartfileURL, atomically: true, encoding: NSUTF8StringEncoding, error: &error) {
			return success(())
		} else {
			return failure(error ?? CarthageError.WriteFailed(resolvedCartfileURL).error)
		}
	}

	/// Returns the URL that the project's remote repository exists at.
	private func repositoryURLForProject(project: ProjectIdentifier) -> GitURL {
		switch project {
		case let .GitHub(repository):
			if preferHTTPS {
				return repository.HTTPSURL
			} else {
				return repository.SSHURL
			}

		case let .Git(URL):
			return URL
		}
	}

	/// Returns the file URL at which the given project's repository will be
	/// located.
	private func repositoryFileURLForProject(project: ProjectIdentifier) -> NSURL {
		return CarthageDependencyRepositoriesURL.URLByAppendingPathComponent(project.name, isDirectory: true)
	}

	/// A scheduler used to serialize all Git operations within this project.
	private let gitOperationScheduler = QueueScheduler()

	/// Runs the given Git operation, blocking the `gitOperationScheduler` until
	/// it has completed.
	private func runGitOperation<T>(operation: ColdSignal<T>) -> ColdSignal<T> {
		return ColdSignal { (sink, disposable) in
			let schedulerDisposable = self.gitOperationScheduler.schedule {
				let results = operation
					.reduce(initial: []) { $0 + [ $1 ] }
					.first()

				switch results {
				case let .Success(values):
					ColdSignal.fromValues(values.unbox).startWithSink { valuesDisposable in
						disposable.addDisposable(valuesDisposable)
						return sink
					}

				case let .Failure(error):
					sink.put(.Error(error))
				}
			}

			disposable.addDisposable(schedulerDisposable)
		}.deliverOn(QueueScheduler())
	}

	/// Clones the given project to the global repositories folder, or fetches
	/// inside it if it has already been cloned.
	///
	/// Returns a signal which will send the URL to the repository's folder on
	/// disk.
	private func cloneOrFetchProject(project: ProjectIdentifier) -> ColdSignal<NSURL> {
		let repositoryURL = repositoryFileURLForProject(project)
		let operation = ColdSignal<NSURL>.lazy {
			var error: NSError?
			if !NSFileManager.defaultManager().createDirectoryAtURL(CarthageDependencyRepositoriesURL, withIntermediateDirectories: true, attributes: nil, error: &error) {
				return .error(error ?? CarthageError.WriteFailed(CarthageDependencyRepositoriesURL).error)
			}

			let remoteURL = self.repositoryURLForProject(project)
			if NSFileManager.defaultManager().createDirectoryAtURL(repositoryURL, withIntermediateDirectories: false, attributes: nil, error: nil) {
				// If we created the directory, we're now responsible for
				// cloning it.
				self._projectEventsSink.put(.Cloning(project))

				return cloneRepository(remoteURL, repositoryURL)
					.then(.single(repositoryURL))
			} else {
				self._projectEventsSink.put(.Fetching(project))

				return fetchRepository(repositoryURL, remoteURL: remoteURL, refspec: "+refs/heads/*:refs/heads/*") /* lol syntax highlighting */
					.then(.single(repositoryURL))
			}
		}

		return runGitOperation(operation)
	}

	/// Sends all versions available for the given project.
	///
	/// This will automatically clone or fetch the project's repository as
	/// necessary.
	private func versionsForProject(project: ProjectIdentifier) -> ColdSignal<PinnedVersion> {
		let fetchVersions = cloneOrFetchProject(project)
			.map { repositoryURL in listTags(repositoryURL) }
			.merge(identity)
			.map { PinnedVersion($0) }
			.on(next: { self.addCachedVersion($0, forProject: project) })

		return readCachedVersions()
			.map { versionsByProject -> ColdSignal<PinnedVersion> in
				if let versions = versionsByProject[project] {
					return .fromValues(versions)
				} else {
					return fetchVersions
				}
			}
			.merge(identity)
	}

	/// Loads the Cartfile for the given dependency, at the given version.
	private func cartfileForDependency(dependency: Dependency<PinnedVersion>) -> ColdSignal<Cartfile> {
		let repositoryURL = repositoryFileURLForProject(dependency.project)

		return contentsOfFileInRepository(repositoryURL, CarthageProjectCartfilePath, revision: dependency.version.commitish)
			.catch { _ in .empty() }
			.tryMap { Cartfile.fromString($0) }
	}

	/// Attempts to resolve a Git reference to a version.
	private func resolvedGitReference(project: ProjectIdentifier, reference: String) -> ColdSignal<PinnedVersion> {
		return cloneOrFetchProject(project)
			.map { repositoryURL in
				return resolveReferenceInRepository(repositoryURL, reference)
			}
			.merge(identity)
			.map { PinnedVersion($0) }
	}

	/// Attempts to determine the latest satisfiable version of the project's
	/// Carthage dependencies.
	///
	/// This will fetch dependency repositories as necessary, but will not check
	/// them out into the project's working directory.
	public func updatedResolvedCartfile() -> ColdSignal<ResolvedCartfile> {
		let resolver = Resolver(versionsForDependency: versionsForProject, cartfileForDependency: cartfileForDependency, resolvedGitReference: resolvedGitReference)

		return resolver.resolveDependenciesInCartfile(self.cartfile)
			.reduce(initial: []) { $0 + [ $1 ] }
			.map { ResolvedCartfile(dependencies: $0) }
	}

	/// Updates the dependencies of the project to the latest version. The
	/// changes will be reflected in the working directory checkouts and
	/// Cartfile.resolved.
	public func updateDependencies() -> ColdSignal<()> {
		return updatedResolvedCartfile()
			.tryMap { resolvedCartfile -> Result<()> in
				return self.writeResolvedCartfile(resolvedCartfile)
			}
			.then(checkoutResolvedDependencies())
	}

	/// Checks out the given project into its intended working directory,
	/// cloning it first if need be.
	private func checkoutOrCloneProject(project: ProjectIdentifier, atRevision revision: String, submodulesByPath: [String: Submodule]) -> ColdSignal<()> {
		let repositoryURL = self.repositoryFileURLForProject(project)
		let workingDirectoryURL = self.directoryURL.URLByAppendingPathComponent(project.relativePath, isDirectory: true)

		let checkoutSignal = ColdSignal<()>.lazy {
				var submodule: Submodule?

				if var foundSubmodule = submodulesByPath[project.relativePath] {
					foundSubmodule.URL = self.repositoryURLForProject(project)
					foundSubmodule.SHA = revision
					submodule = foundSubmodule
				} else if self.useSubmodules {
					submodule = Submodule(name: project.relativePath, path: project.relativePath, URL: self.repositoryURLForProject(project), SHA: revision)
				}

				if let submodule = submodule {
					return self.runGitOperation(addSubmoduleToRepository(self.directoryURL, submodule, GitURL(repositoryURL.path!)))
				} else {
					return checkoutRepositoryToDirectory(repositoryURL, workingDirectoryURL, revision: revision)
				}
			}
			.on(started: {
				self._projectEventsSink.put(.CheckingOut(project, revision))
			})

		let checkoutOrClone = commitExistsInRepository(repositoryURL, revision: revision)
			.map { exists -> ColdSignal<NSURL> in
				if exists {
					return .empty()
				} else {
					return self.cloneOrFetchProject(project)
				}
			}
			.merge(identity)
			.then(checkoutSignal)

		switch project {
		case let .GitHub(repository):
			let installedBinaries: ColdSignal<Bool> = GitHubCredentials.loadFromGit()
				.mergeMap { credentials in
					return releasesForRepository(repository, credentials)
						.filter { release in release.tag == revision && !release.draft && !release.prerelease && !release.assets.isEmpty }
						.take(1)
						.on(next: { release in
							self._projectEventsSink.put(.DownloadingBinaries(project, release.name))
						})
						.concatMap { release in
							return ColdSignal
								.fromValues(release.assets)
								.filter { asset in
									let name = asset.name as NSString
									return name.rangeOfString(CarthageProjectBinaryAssetPattern).location != NSNotFound
								}
								.filter { asset in contains(CarthageProjectBinaryAssetContentTypes, asset.contentType) }
								.concatMap { asset in
									return downloadAsset(asset, credentials)
										.concatMap { downloadURL in cacheDownloadedBinary(project, release, asset, downloadURL) }
								}
						}
				}
				.concatMap { zipURL in unzipArchiveToTemporaryDirectory(zipURL) }
				.concatMap { directoryURL in
					return NSFileManager.defaultManager()
						.rac_enumeratorAtURL(directoryURL, includingPropertiesForKeys: [ NSURLTypeIdentifierKey ], options: NSDirectoryEnumerationOptions.SkipsHiddenFiles | NSDirectoryEnumerationOptions.SkipsPackageDescendants, catchErrors: true)
						.map { enumerator, URL in URL }
						.filter { URL in
							var typeIdentifier: AnyObject?
							if URL.getResourceValue(&typeIdentifier, forKey: NSURLTypeIdentifierKey, error: nil) {
								if let typeIdentifier: AnyObject = typeIdentifier {
									if UTTypeConformsTo(typeIdentifier as String, kUTTypeFramework) != 0 {
										return true
									}
								}
							}

							return false
						}
						.mergeMap { frameworkURL -> ColdSignal<Bool> in
							return architecturesInFramework(frameworkURL)
								.filter { arch in arch.hasPrefix("arm") }
								.map { _ in Platform.iPhoneOS }
								.concat(ColdSignal.single(Platform.MacOSX))
								.take(1)
								.map { platform in self.directoryURL.URLByAppendingPathComponent(platform.relativePath, isDirectory: true) }
								.map { platformFolderURL in platformFolderURL.URLByAppendingPathComponent(frameworkURL.lastPathComponent!) }
								.mergeMap { destinationFrameworkURL in copyFramework(frameworkURL, destinationFrameworkURL) }
								.then(.single(true))
						}
						.takeLast(1)
				}
				.concat(.single(false))
				.take(1)

			return installedBinaries
				.filter { installed in !installed }
				.mergeMap { _ in checkoutOrClone }

		case .Git:
			return checkoutOrClone
		}
	}

	/// Checks out the dependencies listed in the project's Cartfile.resolved.
	public func checkoutResolvedDependencies() -> ColdSignal<()> {
		/// Determine whether the repository currently holds any submodules (if
		/// it even is a repository).
		let submodulesSignal = submodulesInRepository(self.directoryURL)
			.reduce(initial: [:]) { (var submodulesByPath: [String: Submodule], submodule) in
				submodulesByPath[submodule.path] = submodule
				return submodulesByPath
			}

		return ColdSignal<ResolvedCartfile>.lazy {
				return ColdSignal.fromResult(self.readResolvedCartfile())
			}
			.zipWith(submodulesSignal)
			.map { (resolvedCartfile, submodulesByPath) -> ColdSignal<()> in
				return ColdSignal.fromValues(resolvedCartfile.dependencies)
					.map { dependency in
						return self.checkoutOrCloneProject(dependency.project, atRevision: dependency.version.commitish, submodulesByPath: submodulesByPath)
					}
					.merge(identity)
			}
			.merge(identity)
			.then(.empty())
	}

	/// Attempts to build each Carthage dependency that has been checked out.
	///
	/// Returns a signal of all standard output from `xcodebuild`, and a
	/// signal-of-signals representing each scheme being built.
	public func buildCheckedOutDependencies(configuration: String) -> (HotSignal<NSData>, ColdSignal<BuildSchemeSignal>) {
		let (stdoutSignal, stdoutSink) = HotSignal<NSData>.pipe()
		let schemeSignals = ColdSignal<ResolvedCartfile>.lazy {
				return .fromResult(self.readResolvedCartfile())
			}
			.map { resolvedCartfile in ColdSignal.fromValues(resolvedCartfile.dependencies) }
			.merge(identity)
			.map { dependency -> ColdSignal<BuildSchemeSignal> in
				let (buildOutput, schemeSignals) = buildDependencyProject(dependency.project, self.directoryURL, withConfiguration: configuration)
				buildOutput.observe(stdoutSink)

				return schemeSignals
			}
			.concat(identity)

		return (stdoutSignal, schemeSignals)
	}
}

/// Caches the downloaded binary for the given project, returning the new URL to
/// the download.
private func cacheDownloadedBinary(project: ProjectIdentifier, release: GitHubRelease, asset: GitHubRelease.Asset, downloadURL: NSURL) -> ColdSignal<NSURL> {
	return ColdSignal
		.single(CarthageDependencyAssetsURL.URLByAppendingPathComponent("\(project.name)/\(release.tag)", isDirectory: true))
		.try { directoryURL, error in
			return NSFileManager.defaultManager().createDirectoryAtURL(directoryURL, withIntermediateDirectories: true, attributes: nil, error: error)
		}
		.map { $0.URLByAppendingPathComponent("\(asset.ID)-\(asset.name)", isDirectory: false) }
		.try { newDownloadURL, error in
			if rename(downloadURL.fileSystemRepresentation, newDownloadURL.fileSystemRepresentation) == 0 {
				return true
			} else {
				error.memory = NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
				return false
			}
		}
}
