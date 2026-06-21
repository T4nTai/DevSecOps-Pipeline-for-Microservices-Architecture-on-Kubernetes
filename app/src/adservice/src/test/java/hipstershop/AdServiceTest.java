package hipstershop;

import hipstershop.Demo.AdRequest;
import hipstershop.Demo.AdResponse;
import io.grpc.inprocess.InProcessChannelBuilder;
import io.grpc.inprocess.InProcessServerBuilder;
import io.grpc.testing.GrpcCleanupRule;
import org.junit.Rule;
import org.junit.Test;

import static org.junit.Assert.assertFalse;

public class AdServiceTest {

    @Rule
    public final GrpcCleanupRule grpcCleanup = new GrpcCleanupRule();

    private AdServiceGrpc.AdServiceBlockingStub buildStub() throws Exception {
        String serverName = InProcessServerBuilder.generateName();
        grpcCleanup.register(
            InProcessServerBuilder.forName(serverName)
                .directExecutor()
                .addService(new AdService.AdServiceImpl())
                .build()
                .start());
        return AdServiceGrpc.newBlockingStub(
            grpcCleanup.register(
                InProcessChannelBuilder.forName(serverName).directExecutor().build()));
    }

    @Test
    public void getAds_withContextKey_returnsAds() throws Exception {
        AdResponse response = buildStub().getAds(
            AdRequest.newBuilder().addContextKeys("hair").build());
        assertFalse(response.getAdsList().isEmpty());
    }

    @Test
    public void getAds_withoutContextKey_returnsRandomAds() throws Exception {
        AdResponse response = buildStub().getAds(AdRequest.newBuilder().build());
        assertFalse(response.getAdsList().isEmpty());
    }

    @Test
    public void getAds_withUnknownCategory_fallsBackToRandomAds() throws Exception {
        AdResponse response = buildStub().getAds(
            AdRequest.newBuilder().addContextKeys("unknown_xyz").build());
        assertFalse(response.getAdsList().isEmpty());
    }
}
