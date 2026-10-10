namespace Ryujinx.Common.Configuration;
// The portable diagnostic tests never invoke the native export.
internal static class AppDataManager { public static string BaseDirPath => System.IO.Path.GetTempPath(); }
