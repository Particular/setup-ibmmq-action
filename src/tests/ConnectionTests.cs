using System.Collections;
using System.Text;
using IBM.WMQ;
using NUnit.Framework;

[TestFixture]
public class ConnectionTests
{
    static string ConnectionString => Environment.GetEnvironmentVariable("IBMMQ_CONNECTION_STRING")
        ?? throw new InvalidOperationException("Environment variable 'IBMMQ_CONNECTION_STRING' not set.");

    [Test]
    public void Should_connect_to_queue_manager()
    {
        var details = ConnectionDetails.Parse(ConnectionString);

        using var queueManager = Connect(details);

        Assert.That(queueManager.Name.Trim(), Is.EqualTo(details.QueueManagerName));
    }

    [Test]
    public void Should_put_and_get_message()
    {
        var details = ConnectionDetails.Parse(ConnectionString);

        using var queueManager = Connect(details);
        var queue = queueManager.AccessQueue("DEV.QUEUE.1", MQC.MQOO_INPUT_AS_Q_DEF | MQC.MQOO_OUTPUT);

        var message = new MQMessage
        {
            MessageId = Encoding.ASCII.GetBytes(Guid.NewGuid().ToString("N")[..24])
        };
        var content = $"setup-ibmmq-action-{Guid.NewGuid():N}";
        message.WriteString(content);
        queue.Put(message);

        var received = new MQMessage
        {
            MessageId = message.MessageId
        };
        var getOptions = new MQGetMessageOptions
        {
            MatchOptions = MQC.MQMO_MATCH_MSG_ID,
            WaitInterval = 5000
        };
        queue.Get(received, getOptions);

        Assert.That(received.ReadString(received.MessageLength), Is.EqualTo(content));
    }

    static MQQueueManager Connect(ConnectionDetails details) => new(
        details.QueueManagerName,
        new Hashtable
        {
            { MQC.TRANSPORT_PROPERTY, MQC.TRANSPORT_MQSERIES_MANAGED },
            { MQC.HOST_NAME_PROPERTY, details.Host },
            { MQC.PORT_PROPERTY, details.Port },
            { MQC.CHANNEL_PROPERTY, details.Channel },
            { MQC.USER_ID_PROPERTY, details.User },
            { MQC.PASSWORD_PROPERTY, details.Password }
        });

    sealed record ConnectionDetails(string Host, int Port, string User, string Password, string QueueManagerName, string Channel)
    {
        public static ConnectionDetails Parse(string connectionString)
        {
            var uri = new Uri(connectionString);
            var userInfo = uri.UserInfo.Split(':', 2);
            var query = uri.Query.TrimStart('?')
                .Split('&', StringSplitOptions.RemoveEmptyEntries)
                .Select(part => part.Split('=', 2))
                .ToDictionary(parts => parts[0], parts => Uri.UnescapeDataString(parts[1]));

            return new ConnectionDetails(
                uri.Host,
                uri.Port > 0 ? uri.Port : 1414,
                Uri.UnescapeDataString(userInfo[0]),
                Uri.UnescapeDataString(userInfo[1]),
                Uri.UnescapeDataString(uri.AbsolutePath.Trim('/')) is { Length: > 0 } path ? path : "QM1",
                query.GetValueOrDefault("channel", "DEV.ADMIN.SVRCONN"));
        }
    }
}
