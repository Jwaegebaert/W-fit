using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;

namespace WFit.Api.Data;

public static class Len
{
    public const int Guid = 36;
    public const int CatalogId = 64;
    public const int Code = 16;
    public const int Name = 100;
    public const int Title = 200;
    public const int Text = 2000;
    public const int Goals = 500;
}

public sealed class WFitDbContext(DbContextOptions<WFitDbContext> options) : DbContext(options)
{
    public DbSet<Profile> Profiles => Set<Profile>();
    public DbSet<EquipmentStatus> EquipmentStatuses => Set<EquipmentStatus>();
    public DbSet<ExercisePreference> ExercisePreferences => Set<ExercisePreference>();
    public DbSet<PlannedWorkout> PlannedWorkouts => Set<PlannedWorkout>();
    public DbSet<WorkoutSession> WorkoutSessions => Set<WorkoutSession>();
    public DbSet<SetLog> SetLogs => Set<SetLog>();
    public DbSet<BodyMetric> BodyMetrics => Set<BodyMetric>();
    public DbSet<CatalogExercise> CatalogExercises => Set<CatalogExercise>();
    public DbSet<CatalogEquipment> CatalogEquipment => Set<CatalogEquipment>();
    public DbSet<AppMeta> AppMeta => Set<AppMeta>();
    public DbSet<AiUsage> AiUsage => Set<AiUsage>();
    public DbSet<InsightsCache> InsightsCache => Set<InsightsCache>();

    protected override void OnModelCreating(ModelBuilder b)
    {
        b.Entity<Profile>(e =>
        {
            e.HasKey(x => x.Id);
            e.Property(x => x.Id).HasMaxLength(Len.Guid);
            e.Property(x => x.Name).HasMaxLength(Len.Name);
            e.Property(x => x.Experience).HasMaxLength(Len.Code);
            e.Property(x => x.Goals).HasMaxLength(Len.Goals);
            e.Property(x => x.Injuries).HasMaxLength(Len.Text);
            e.Property(x => x.Notes).HasMaxLength(Len.Text);
            Sync(e);
        });

        b.Entity<EquipmentStatus>(e =>
        {
            e.HasKey(x => x.EquipmentId);
            e.Property(x => x.EquipmentId).HasMaxLength(Len.CatalogId);
            Sync(e);
        });

        b.Entity<ExercisePreference>(e =>
        {
            e.HasKey(x => x.ExerciseId);
            e.Property(x => x.ExerciseId).HasMaxLength(Len.CatalogId);
            e.Property(x => x.Preference).HasMaxLength(Len.Code);
            e.Property(x => x.Note).HasMaxLength(Len.Text);
            Sync(e);
        });

        b.Entity<PlannedWorkout>(e =>
        {
            e.HasKey(x => x.Id);
            e.Property(x => x.Id).HasMaxLength(Len.Guid);
            e.Property(x => x.DayType).HasMaxLength(Len.Code);
            e.Property(x => x.Title).HasMaxLength(Len.Title);
            e.Property(x => x.Source).HasMaxLength(Len.Code);
            e.Property(x => x.Status).HasMaxLength(Len.Code);
            e.Property(x => x.CoachNote).HasMaxLength(Len.Text);
            e.Property(x => x.BlocksJson).HasColumnName("Blocks");
            e.HasIndex(x => x.Date);
            Sync(e);
        });

        b.Entity<WorkoutSession>(e =>
        {
            e.HasKey(x => x.Id);
            e.Property(x => x.Id).HasMaxLength(Len.Guid);
            e.Property(x => x.PlannedWorkoutId).HasMaxLength(Len.Guid);
            e.Property(x => x.DayType).HasMaxLength(Len.Code);
            e.Property(x => x.Title).HasMaxLength(Len.Title);
            e.Property(x => x.Notes).HasMaxLength(Len.Text);
            e.HasIndex(x => x.StartedAt);
            Sync(e);
        });

        b.Entity<SetLog>(e =>
        {
            e.HasKey(x => x.Id);
            e.Property(x => x.Id).HasMaxLength(Len.Guid);
            e.Property(x => x.SessionId).HasMaxLength(Len.Guid);
            e.Property(x => x.ExerciseId).HasMaxLength(Len.CatalogId);
            e.Property(x => x.Section).HasMaxLength(Len.Code);
            e.HasIndex(x => x.SessionId);
            e.HasIndex(x => x.ExerciseId);
            Sync(e);
        });

        b.Entity<BodyMetric>(e =>
        {
            e.HasKey(x => x.Id);
            e.Property(x => x.Id).HasMaxLength(Len.Guid);
            e.Property(x => x.Notes).HasMaxLength(Len.Text);
            e.HasIndex(x => x.Date);
            Sync(e);
        });

        b.Entity<CatalogExercise>(e =>
        {
            e.HasKey(x => x.Id);
            e.Property(x => x.Id).HasMaxLength(Len.CatalogId);
            e.Property(x => x.Name).HasMaxLength(Len.Name);
            e.Property(x => x.Category).HasMaxLength(Len.Code);
            e.Property(x => x.Pattern).HasMaxLength(Len.CatalogId);
            e.Property(x => x.Measure).HasMaxLength(Len.Code);
            e.Property(x => x.Badminton).HasMaxLength(Len.Text);
            e.Property(x => x.Tip).HasMaxLength(Len.Text);
        });

        b.Entity<CatalogEquipment>(e =>
        {
            e.HasKey(x => x.Id);
            e.Property(x => x.Id).HasMaxLength(Len.CatalogId);
            e.Property(x => x.Name).HasMaxLength(Len.Name);
            e.Property(x => x.Group).HasMaxLength(Len.CatalogId);
        });

        b.Entity<AppMeta>(e =>
        {
            e.HasKey(x => x.Key);
            e.Property(x => x.Key).HasMaxLength(Len.Name);
        });

        b.Entity<AiUsage>(e => e.HasKey(x => x.Day));

        b.Entity<InsightsCache>(e => e.HasKey(x => x.Day));
    }

    private static void Sync<T>(EntityTypeBuilder<T> e) where T : SyncEntity
    {
        e.HasIndex(x => x.ServerUpdatedAt);
    }
}
