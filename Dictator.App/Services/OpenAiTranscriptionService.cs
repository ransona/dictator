using System.Net.Http.Headers;

namespace Dictator.App.Services;

internal sealed class OpenAiTranscriptionService
{
    private readonly HttpClient httpClient = new()
    {
        Timeout = TimeSpan.FromMinutes(2)
    };

    public async Task<string> TranscribeAsync(
        byte[] audioBytes,
        string apiKey,
        string model,
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.openai.com/v1/audio/transcriptions");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);

        using var multipart = new MultipartFormDataContent();
        var audioContent = new ByteArrayContent(audioBytes);
        audioContent.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        multipart.Add(audioContent, "file", "dictation.wav");
        multipart.Add(new StringContent(model), "model");
        multipart.Add(new StringContent("text"), "response_format");
        request.Content = multipart;

        using var response = await httpClient.SendAsync(request, cancellationToken);
        var responseBody = await response.Content.ReadAsStringAsync(cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"OpenAI returned {(int)response.StatusCode}: {responseBody}");
        }

        return responseBody.Trim();
    }
}
