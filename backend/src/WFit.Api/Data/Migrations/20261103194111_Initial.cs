using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace WFit.Api.Data.Migrations
{
    /// <inheritdoc />
    public partial class Initial : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "AiUsage",
                columns: table => new
                {
                    Day = table.Column<DateOnly>(type: "date", nullable: false),
                    Calls = table.Column<int>(type: "int", nullable: false),
                    InputTokens = table.Column<long>(type: "bigint", nullable: false),
                    OutputTokens = table.Column<long>(type: "bigint", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_AiUsage", x => x.Day);
                });

            migrationBuilder.CreateTable(
                name: "AppMeta",
                columns: table => new
                {
                    Key = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: false),
                    Value = table.Column<string>(type: "nvarchar(max)", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_AppMeta", x => x.Key);
                });

            migrationBuilder.CreateTable(
                name: "BodyMetrics",
                columns: table => new
                {
                    Id = table.Column<string>(type: "nvarchar(36)", maxLength: 36, nullable: false),
                    Date = table.Column<DateOnly>(type: "date", nullable: false),
                    WeightKg = table.Column<double>(type: "float", nullable: true),
                    BodyFatPct = table.Column<double>(type: "float", nullable: true),
                    WaistCm = table.Column<double>(type: "float", nullable: true),
                    ChestCm = table.Column<double>(type: "float", nullable: true),
                    ArmCm = table.Column<double>(type: "float", nullable: true),
                    ThighCm = table.Column<double>(type: "float", nullable: true),
                    HipsCm = table.Column<double>(type: "float", nullable: true),
                    Notes = table.Column<string>(type: "nvarchar(2000)", maxLength: 2000, nullable: false),
                    UpdatedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: false),
                    ServerUpdatedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: false),
                    Deleted = table.Column<bool>(type: "bit", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_BodyMetrics", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "CatalogEquipment",
                columns: table => new
                {
                    Id = table.Column<string>(type: "nvarchar(64)", maxLength: 64, nullable: false),
                    Name = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: false),
                    Group = table.Column<string>(type: "nvarchar(64)", maxLength: 64, nullable: false),
                    AlwaysAvailable = table.Column<bool>(type: "bit", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_CatalogEquipment", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "CatalogExercises",
                columns: table => new
                {
                    Id = table.Column<string>(type: "nvarchar(64)", maxLength: 64, nullable: false),
                    Name = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: false),
                    Category = table.Column<string>(type: "nvarchar(16)", maxLength: 16, nullable: false),
                    Pattern = table.Column<string>(type: "nvarchar(64)", maxLength: 64, nullable: false),
                    Splits = table.Column<string>(type: "nvarchar(max)", nullable: false),
                    Primary = table.Column<string>(type: "nvarchar(max)", nullable: false),
                    Secondary = table.Column<string>(type: "nvarchar(max)", nullable: false),
                    Equipment = table.Column<string>(type: "nvarchar(max)", nullable: false),
                    Difficulty = table.Column<int>(type: "int", nullable: false),
                    Compound = table.Column<bool>(type: "bit", nullable: false),
                    Unilateral = table.Column<bool>(type: "bit", nullable: false),
                    Measure = table.Column<string>(type: "nvarchar(16)", maxLength: 16, nullable: false),
                    Sets = table.Column<int>(type: "int", nullable: false),
                    RepMin = table.Column<int>(type: "int", nullable: true),
                    RepMax = table.Column<int>(type: "int", nullable: true),
                    DurationSeconds = table.Column<int>(type: "int", nullable: true),
                    RestSeconds = table.Column<int>(type: "int", nullable: false),
                    IncrementKg = table.Column<double>(type: "float", nullable: false),
                    Badminton = table.Column<string>(type: "nvarchar(2000)", maxLength: 2000, nullable: true),
                    Instructions = table.Column<string>(type: "nvarchar(max)", nullable: false),
                    Tip = table.Column<string>(type: "nvarchar(2000)", maxLength: 2000, nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_CatalogExercises", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "EquipmentStatuses",
                columns: table => new
                {
                    EquipmentId = table.Column<string>(type: "nvarchar(64)", maxLength: 64, nullable: false),
                    Available = table.Column<bool>(type: "bit", nullable: false),
                    UpdatedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: false),
                    ServerUpdatedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: false),
                    Deleted = table.Column<bool>(type: "bit", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_EquipmentStatuses", x => x.EquipmentId);
                });

            migrationBuilder.CreateTable(
                name: "ExercisePreferences",
                columns: table => new
                {
                    ExerciseId = table.Column<string>(type: "nvarchar(64)", maxLength: 64, nullable: false),
                    Preference = table.Column<string>(type: "nvarchar(16)", maxLength: 16, nullable: false),
                    Note = table.Column<string>(type: "nvarchar(2000)", maxLength: 2000, nullable: false),
                    UpdatedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: false),
                    ServerUpdatedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: false),
                    Deleted = table.Column<bool>(type: "bit", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_ExercisePreferences", x => x.ExerciseId);
                });

            migrationBuilder.CreateTable(
                name: "InsightsCache",
                columns: table => new
                {
                    Day = table.Column<DateOnly>(type: "date", nullable: false),
                    Json = table.Column<string>(type: "nvarchar(max)", nullable: false),
                    GeneratedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_InsightsCache", x => x.Day);
                });

            migrationBuilder.CreateTable(
                name: "PlannedWorkouts",
                columns: table => new
                {
                    Id = table.Column<string>(type: "nvarchar(36)", maxLength: 36, nullable: false),
                    Date = table.Column<DateOnly>(type: "date", nullable: false),
                    DayType = table.Column<string>(type: "nvarchar(16)", maxLength: 16, nullable: false),
                    Title = table.Column<string>(type: "nvarchar(200)", maxLength: 200, nullable: false),
                    Source = table.Column<string>(type: "nvarchar(16)", maxLength: 16, nullable: false),
                    Status = table.Column<string>(type: "nvarchar(16)", maxLength: 16, nullable: false),
                    EstimatedMinutes = table.Column<int>(type: "int", nullable: false),
                    CoachNote = table.Column<string>(type: "nvarchar(2000)", maxLength: 2000, nullable: false),
                    Blocks = table.Column<string>(type: "nvarchar(max)", nullable: false),
                    UpdatedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: false),
                    ServerUpdatedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: false),
                    Deleted = table.Column<bool>(type: "bit", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_PlannedWorkouts", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "Profiles",
                columns: table => new
                {
                    Id = table.Column<string>(type: "nvarchar(36)", maxLength: 36, nullable: false),
                    Name = table.Column<string>(type: "nvarchar(100)", maxLength: 100, nullable: false),
                    Experience = table.Column<string>(type: "nvarchar(16)", maxLength: 16, nullable: false),
                    Goals = table.Column<string>(type: "nvarchar(500)", maxLength: 500, nullable: false),
                    TrainingDays = table.Column<string>(type: "nvarchar(max)", nullable: false),
                    SessionMinutes = table.Column<int>(type: "int", nullable: false),
                    IncludeCore = table.Column<bool>(type: "bit", nullable: false),
                    HeightCm = table.Column<double>(type: "float", nullable: true),
                    BirthYear = table.Column<int>(type: "int", nullable: true),
                    Injuries = table.Column<string>(type: "nvarchar(2000)", maxLength: 2000, nullable: false),
                    Notes = table.Column<string>(type: "nvarchar(2000)", maxLength: 2000, nullable: false),
                    UpdatedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: false),
                    ServerUpdatedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: false),
                    Deleted = table.Column<bool>(type: "bit", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_Profiles", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "SetLogs",
                columns: table => new
                {
                    Id = table.Column<string>(type: "nvarchar(36)", maxLength: 36, nullable: false),
                    SessionId = table.Column<string>(type: "nvarchar(36)", maxLength: 36, nullable: false),
                    ExerciseId = table.Column<string>(type: "nvarchar(64)", maxLength: 64, nullable: false),
                    Section = table.Column<string>(type: "nvarchar(16)", maxLength: 16, nullable: false),
                    ExerciseOrder = table.Column<int>(type: "int", nullable: false),
                    SetNumber = table.Column<int>(type: "int", nullable: false),
                    WeightKg = table.Column<double>(type: "float", nullable: true),
                    Reps = table.Column<int>(type: "int", nullable: true),
                    DurationSeconds = table.Column<int>(type: "int", nullable: true),
                    Rir = table.Column<int>(type: "int", nullable: true),
                    Completed = table.Column<bool>(type: "bit", nullable: false),
                    CompletedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: true),
                    UpdatedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: false),
                    ServerUpdatedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: false),
                    Deleted = table.Column<bool>(type: "bit", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_SetLogs", x => x.Id);
                });

            migrationBuilder.CreateTable(
                name: "WorkoutSessions",
                columns: table => new
                {
                    Id = table.Column<string>(type: "nvarchar(36)", maxLength: 36, nullable: false),
                    PlannedWorkoutId = table.Column<string>(type: "nvarchar(36)", maxLength: 36, nullable: true),
                    DayType = table.Column<string>(type: "nvarchar(16)", maxLength: 16, nullable: false),
                    Title = table.Column<string>(type: "nvarchar(200)", maxLength: 200, nullable: false),
                    StartedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: false),
                    EndedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: true),
                    DurationSeconds = table.Column<int>(type: "int", nullable: true),
                    Rating = table.Column<int>(type: "int", nullable: true),
                    PerceivedEffort = table.Column<int>(type: "int", nullable: true),
                    Notes = table.Column<string>(type: "nvarchar(2000)", maxLength: 2000, nullable: false),
                    UpdatedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: false),
                    ServerUpdatedAt = table.Column<DateTimeOffset>(type: "datetimeoffset", nullable: false),
                    Deleted = table.Column<bool>(type: "bit", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_WorkoutSessions", x => x.Id);
                });

            migrationBuilder.CreateIndex(
                name: "IX_BodyMetrics_Date",
                table: "BodyMetrics",
                column: "Date");

            migrationBuilder.CreateIndex(
                name: "IX_BodyMetrics_ServerUpdatedAt",
                table: "BodyMetrics",
                column: "ServerUpdatedAt");

            migrationBuilder.CreateIndex(
                name: "IX_EquipmentStatuses_ServerUpdatedAt",
                table: "EquipmentStatuses",
                column: "ServerUpdatedAt");

            migrationBuilder.CreateIndex(
                name: "IX_ExercisePreferences_ServerUpdatedAt",
                table: "ExercisePreferences",
                column: "ServerUpdatedAt");

            migrationBuilder.CreateIndex(
                name: "IX_PlannedWorkouts_Date",
                table: "PlannedWorkouts",
                column: "Date");

            migrationBuilder.CreateIndex(
                name: "IX_PlannedWorkouts_ServerUpdatedAt",
                table: "PlannedWorkouts",
                column: "ServerUpdatedAt");

            migrationBuilder.CreateIndex(
                name: "IX_Profiles_ServerUpdatedAt",
                table: "Profiles",
                column: "ServerUpdatedAt");

            migrationBuilder.CreateIndex(
                name: "IX_SetLogs_ExerciseId",
                table: "SetLogs",
                column: "ExerciseId");

            migrationBuilder.CreateIndex(
                name: "IX_SetLogs_ServerUpdatedAt",
                table: "SetLogs",
                column: "ServerUpdatedAt");

            migrationBuilder.CreateIndex(
                name: "IX_SetLogs_SessionId",
                table: "SetLogs",
                column: "SessionId");

            migrationBuilder.CreateIndex(
                name: "IX_WorkoutSessions_ServerUpdatedAt",
                table: "WorkoutSessions",
                column: "ServerUpdatedAt");

            migrationBuilder.CreateIndex(
                name: "IX_WorkoutSessions_StartedAt",
                table: "WorkoutSessions",
                column: "StartedAt");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "AiUsage");

            migrationBuilder.DropTable(
                name: "AppMeta");

            migrationBuilder.DropTable(
                name: "BodyMetrics");

            migrationBuilder.DropTable(
                name: "CatalogEquipment");

            migrationBuilder.DropTable(
                name: "CatalogExercises");

            migrationBuilder.DropTable(
                name: "EquipmentStatuses");

            migrationBuilder.DropTable(
                name: "ExercisePreferences");

            migrationBuilder.DropTable(
                name: "InsightsCache");

            migrationBuilder.DropTable(
                name: "PlannedWorkouts");

            migrationBuilder.DropTable(
                name: "Profiles");

            migrationBuilder.DropTable(
                name: "SetLogs");

            migrationBuilder.DropTable(
                name: "WorkoutSessions");
        }
    }
}
