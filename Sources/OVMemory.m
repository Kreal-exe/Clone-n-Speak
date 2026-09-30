#import "OVMemory.h"
#import "OVLocale.h"
#import <mach/mach.h>
#import <libproc.h>

@implementation OVMemory

+ (unsigned long long)availableBytes {
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS) return 0;
    vm_size_t page = 0;
    host_page_size(mach_host_self(), &page);
    unsigned long long pages = (unsigned long long)vm.free_count + vm.inactive_count + vm.purgeable_count + vm.speculative_count;
    return pages * page;
}

+ (unsigned long long)footprintOfPID:(pid_t)pid {
    if (pid <= 0) return 0;
    struct rusage_info_v2 info;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&info) != 0) return 0;
    return info.ri_phys_footprint;
}

/// Peak footprint measured on Apple Silicon (model + activations + Python/MLX runtime).
+ (unsigned long long)needFor:(OVEngineKind)kind bits:(NSInteger)bits {
    double gb;
    if (kind == OVEngineTTS) gb = bits >= 16 ? 3.0 : bits >= 8 ? 2.3 : 2.0;   // OmniVoice (sentence by sentence)
    else                     gb = bits >= 16 ? 1.9 : bits >= 8 ? 1.2 : 0.7;   // Whisper large-v3-turbo
    return (unsigned long long)(gb * 1024 * 1024 * 1024);
}

+ (NSInteger)bitsFor:(OVEngineKind)kind budget:(unsigned long long)budget {
    for (NSNumber *b in @[@16, @8]) // 4-bit only as the last resort: it hurts quality noticeably
        if (budget >= [self needFor:kind bits:b.integerValue]) return b.integerValue;
    return 4;
}

+ (NSString *)format:(unsigned long long)bytes {
    return [NSString stringWithFormat:L(@"%.1f GB"), bytes / 1073741824.0];
}
@end
