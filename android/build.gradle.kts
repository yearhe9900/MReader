import com.android.build.api.dsl.CommonExtension

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// ---------------------------------------------------------------------------
// 统一提升插件模块的 compileSdk（全局 Gradle 配置，影响**所有**子工程）。
//
// ⚠️ 顺序敏感：本段必须注册在下方 `evaluationDependsOn(":app")` **之前**——
//   Flutter 模板在 root 评估期就会强制评估 :app，若晚于它注册 afterEvaluate，
//   会抛「Cannot run Project.afterEvaluate(Action) when the project is already evaluated」。
//
// 现象：`:jni_flutter:checkDebugAarMetadata` 失败——
//   `Dependency ':jni' requires ... version 36 or later of the Android APIs.
//    :jni_flutter is currently compiled against android-35.`
//
// 根因链：
//   path_provider 2.3.x 的 Android 实现（path_provider_android 2.3.1）改走 JNI
//   → 引入 jni 1.0.3 / jni_flutter 1.0.3
//   → jni 1.0.3 的 AAR metadata 要求**消费者** compileSdk ≥ 36
//   → 而 jni_flutter 插件自身的 build.gradle 仍硬编码 compileSdk 35。
//   因此只改 :app 的 compileSdk 无效——报错的是插件模块自己的编译目标。
//
// 修法：对每个 Android 子工程，在评估完成后（afterEvaluate）检查其 compileSdk，
//   **仅当低于 36 时**提升到 36；不做无条件覆盖，插件未来自己升到 37 也不会被压回。
//   compileSdk 为 null 表示模块未显式设置、使用 AGP 默认值（AGP 9 默认即 36），不动。
//
// 类型说明：这里用 `com.android.build.api.dsl.CommonExtension`（新 DSL）而非
//   旧类型 `com.android.build.gradle.BaseExtension`——本工程 AGP 为 9.0.1，
//   AGP 9.0 已移除 BaseExtension；且 CommonExtension 自 AGP 9.0 起不再带泛型参数，
//   `compileSdk` 为可读写属性（Int?）。
//
// 后续：待 jni_flutter（或上游 path_provider）自身把 compileSdk 升到 ≥ 36 后，
//   本段可整体删除。
val minRequiredPluginCompileSdk = 36
subprojects {
    afterEvaluate {
        val androidExtension = extensions.findByName("android") ?: return@afterEvaluate
        if (androidExtension is CommonExtension) {
            val currentSdk: Int? = androidExtension.compileSdk
            if (currentSdk != null && currentSdk < minRequiredPluginCompileSdk) {
                androidExtension.compileSdk = minRequiredPluginCompileSdk
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
