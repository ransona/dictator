using System.Threading;

namespace Dictator.App;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        using var mutex = new Mutex(true, @"Local\Dictator.App", out var createdNew);
        if (!createdNew)
        {
            return;
        }

        ApplicationConfiguration.Initialize();
        using var context = new DictatorApplicationContext();
        Application.Run(context);
        GC.KeepAlive(mutex);
    }
}
