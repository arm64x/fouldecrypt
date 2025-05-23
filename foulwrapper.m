#import <stdio.h>
#import <spawn.h>
#import <objc/runtime.h>

#import <AppList/AppList.h>
#import <Foundation/Foundation.h>

#import <MobileContainerManager/MCMContainer.h>
#import <MobileCoreServices/LSApplicationProxy.h>

static int VERBOSE = 0;

#define MH_MAGIC      0xfeedface
#define MH_CIGAM      0xcefaedfe
#define MH_MAGIC_64   0xfeedfacf  /* the 64-bit mach magic number */
#define MH_CIGAM_64   0xcffaedfe  /* NXSwapInt(MH_MAGIC_64) */

#define FAT_MAGIC     0xcafebabe
#define FAT_CIGAM     0xbebafeca
#define FAT_MAGIC_64  0xcafebabf
#define FAT_CIGAM_64  0xbfbafeca  /* NXSwapLong(FAT_MAGIC_64) */

#define LC_SEGMENT              0x1
#define LC_SEGMENT_64           0x19
#define LC_ENCRYPTION_INFO      0x21
#define LC_ENCRYPTION_INFO_64   0x2C

extern char **environ;

int
my_system(const char *ctx)
{
    const char *args[] = {
        "/bin/sh",
        "-c",
        ctx,
        NULL
    };
    pid_t pid;
    int posix_status = posix_spawn(&pid, "/bin/sh", NULL, NULL, (char **) args, environ);
    if (posix_status != 0)
    {
        errno = posix_status;
        fprintf(stderr, "posix_spawn, %s (%d)\n", strerror(errno), errno);
        return posix_status;
    }
    pid_t w;
    int status;
    do
    {
        w = waitpid(pid, &status, WUNTRACED | WCONTINUED);
        if (w == -1)
        {
            fprintf(stderr, "waitpid %d, %s (%d)\n", pid, strerror(errno), errno);
            return errno;
        }
        if (WIFEXITED(status))
        {
            if (WEXITSTATUS(status) != 0)
            {
                fprintf(stderr, "pid %d, exited with status %d\n", pid, WEXITSTATUS(status));
                return WEXITSTATUS(status);
            }
        }
        else if (WIFSIGNALED(status))
        {
            fprintf(stderr, "pid %d killed by signal %d\n", pid, WTERMSIG(status));
        }
        else if (WIFSTOPPED(status))
        {
            fprintf(stderr, "pid %d stopped by signal %d\n", pid, WSTOPSIG(status));
        }
        // else if (WIFCONTINUED(status))
        // {
        //     // fprintf(stderr, "pid %d continued\n", pid);
        // }
    }
    while (!WIFEXITED(status) && !WIFSIGNALED(status));
    if (WIFSIGNALED(status))
    {
        return WTERMSIG(status);
    }
    return WEXITSTATUS(status);
}

NSString *
escape_arg(NSString *arg)
{
    return [arg stringByReplacingOccurrencesOfString:@"\'" withString:@"'\\\''"];
}

@interface LSApplicationProxy ()
- (NSString *)shortVersionString;
@end

int
main(int argc, char *argv[])
{
    if (argc < 2)
    {
        fprintf(stderr, "usage: foulwrapper (application name or application bundle identifier)\n");
        return 1;
    }


    /* AppList: convert app name to app identifier */
    /* or, you can use APIs in `LSApplicationWorkspace`. */
    NSArray *sortedDisplayIdentifiers = nil;
    NSDictionary *appMaps =
        [[ALApplicationList sharedApplicationList] applicationsFilteredUsingPredicate:[NSPredicate predicateWithFormat:@"isSystemApplication = FALSE"]
                                                                          onlyVisible:NO titleSortedIdentifiers:&sortedDisplayIdentifiers];

    NSString *targetIdOrName = [NSString stringWithUTF8String:argv[1]];
    NSString *targetId = nil;
    for (NSString *appId in appMaps)
    {
        if ([appId isEqualToString:targetIdOrName] || [appMaps[appId] isEqualToString:targetIdOrName])
        {
            targetId = appId;
            break;
        }
    }

    if (!targetId) {
        targetId = [NSString stringWithUTF8String:argv[2]];
    }

    if (!targetId)
    {
        fprintf(stderr, "Application \"%s\" not found\n", argv[1]);
        return 1;
    }

    /* MobileContainerManager: locate app bundle container path */
    /* `LSApplicationProxy` cannot provide correct values of container URLs since iOS 12. */
    NSError *error = nil;
    id aClass = objc_getClass("MCMAppContainer");
    assert([aClass respondsToSelector:@selector(containerWithIdentifier:error:)]);

    MCMContainer *container = [aClass containerWithIdentifier:targetId error:&error];
    NSString *targetPath = [[container url] path];
    if (!targetPath)
    {
        fprintf(stderr,
                "Application \"%s\" does not have a bundle container: %s\n",
                argv[1],
                [[error localizedDescription] UTF8String]);
        return 1;
    }

    fprintf(stderr, "[start] Target app -> %s\n", [targetId UTF8String]);  

    /* Make a copy of app bundle. */
    NSURL *tempURL = [[NSFileManager defaultManager] URLForDirectory:NSItemReplacementDirectory
                                                            inDomain:NSUserDomainMask
                                                   appropriateForURL:[NSURL fileURLWithPath:[[NSFileManager defaultManager] currentDirectoryPath]]
                                                              create:YES
                                                              error:&error];
    if (!tempURL) {
        fprintf(stderr,
                "cannot create appropriate item replacement directory: %s\n",
                [[error localizedDescription] UTF8String]);
        return 1;
    }

    NSString *tempPath = [[tempURL path] stringByAppendingPathComponent:@"Payload"];
    BOOL didCopy = [[NSFileManager defaultManager] copyItemAtPath:targetPath toPath:tempPath error:&error];
    if (!didCopy) {
        fprintf(stderr, "cannot copy app bundle: %s\n", [[error localizedDescription] UTF8String]);
        return 1;
    }

    /* Enumerate entire app bundle to find all Mach-Os. */
    NSEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:tempPath];
    NSString *objectPath = nil;
    BOOL didError = 0;
    NSNumber *decryptCount = [NSNumber numberWithInteger: 0];
    while (objectPath = [enumerator nextObject])
    {
        NSString *objectFullPath = [tempPath stringByAppendingPathComponent:objectPath];
        FILE *fp = fopen(objectFullPath.UTF8String, "rb");
        if (!fp)
        {
            perror("fopen");
            continue;
        }

        int num = getw(fp);
        if (num == EOF)
        {
            fclose(fp);
            continue;
        }

        if (
            [objectPath containsString:@".app/Info.plist"]
        ) {
            fclose(fp);
            fprintf(stderr, "[change] %s: Remove UISupportedDevices\n", [objectPath UTF8String]);
            NSMutableDictionary *infoPlist = [NSMutableDictionary dictionaryWithContentsOfFile:objectFullPath];
            [infoPlist removeObjectForKey:@"UISupportedDevices"];
            [infoPlist writeToFile:objectPath atomically:YES];
            continue;
        }

        if (
            num == MH_MAGIC_64 ||
            num == MH_MAGIC ||
            num == FAT_MAGIC_64 ||
            num == FAT_MAGIC ||
            num == MH_CIGAM ||
            num == MH_CIGAM_64 ||
            num == FAT_CIGAM ||
            num == FAT_CIGAM_64
        ) {
            NSString *objectRawPath = [targetPath stringByAppendingPathComponent:objectPath];

            int decryptStatus =
                my_system([[NSString stringWithFormat:@"fouldecrypt '%@' '%@'", escape_arg(objectRawPath), escape_arg(
                    objectFullPath)] UTF8String]);
            if (decryptStatus != 0) {
                didError = decryptStatus;
                fprintf(stderr, "[dump] %s: Failed\n", [objectPath UTF8String]);
                break;
            }

            decryptCount = [NSNumber numberWithInteger: [decryptCount integerValue] + 1];
            fprintf(stderr, "[dump] %s: Success\n", [objectPath UTF8String]);
        }

        fclose(fp);
    }

    if (didError) {
        return didError;
    }

    if ([decryptCount integerValue] == 0) {
        fprintf(stderr, "[dump] no Mach-O found\n");
        return 1;
    }

    LSApplicationProxy *appProxy = [LSApplicationProxy applicationProxyForIdentifier:targetId];
    assert(appProxy);

    /* Sign the app bundle. */
    NSString *decryptSign = [tempPath stringByAppendingPathComponent:@"decrypt.day"];
    [[NSFileManager defaultManager] createFileAtPath:decryptSign contents:[@"und3fined" dataUsingEncoding:NSUTF8StringEncoding] attributes:nil];

    // NSString *infoPlistPath = [tempPath stringByAppendingPathComponent:@"Info.plist"];
    // NSMutableDictionary *infoPlist = [NSMutableDictionary dictionaryWithContentsOfFile:infoPlistPath];
    // assert(infoPlist);

    // /* Remove UISupportedDevices in Info.plist file */
    // [infoPlist removeObjectForKey:@"UISupportedDevices"];
    // [infoPlist writeToFile:infoPlistPath atomically:YES];

    /* remove other files */
    NSString *mobileContainerManager = [tempPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
    NSString *bundleMetadata = [tempPath stringByAppendingPathComponent:@"BundleMetadata.plist"];
    NSString *iTunesMetadata = [tempPath stringByAppendingPathComponent:@"iTunesMetadata.plist"];
    [[NSFileManager defaultManager] removeItemAtPath:mobileContainerManager error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:bundleMetadata error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:iTunesMetadata error:nil];
    
    /* zip: archive */
    NSString *archiveName =
        [NSString stringWithFormat:@"%@_%@_dump.ipa", targetId, [appProxy shortVersionString]];
    NSString *archivePath =
        [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:archiveName];

    BOOL didClean = [[NSFileManager defaultManager] removeItemAtPath:archivePath error:nil];
    fprintf(stderr, "[archive] Creating %s file...\n", [archiveName UTF8String]);

    int zipStatus =
        my_system([[
            NSString stringWithFormat:@"set -e; shopt -s dotglob; cd '%@'; zip -qrX '%@' ./Payload; shopt -u dotglob;",
            escape_arg([tempURL path]),
            escape_arg(archivePath)
        ] UTF8String]);

    fprintf(stderr, "[archive] Archive -> %s\n", [archiveName UTF8String]);
    fprintf(stderr, "[clean] Remove temp %s\n", [[tempURL path] UTF8String]);
    [[NSFileManager defaultManager] removeItemAtPath:[tempURL path] error:nil];

    if (zipStatus != 0) {
        fprintf(stderr, "cannot create archive: %s\n", [[error localizedDescription] UTF8String]);
        return 1;
    }

    fprintf(stderr, "Done.\n");
    return zipStatus;
}
