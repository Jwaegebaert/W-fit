using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace WFit.Api.Data.Migrations
{
    /// <inheritdoc />
    public partial class ProfileTrainingPrefs : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "BarWeightsJson",
                table: "Profiles",
                type: "nvarchar(2000)",
                maxLength: 2000,
                nullable: false,
                defaultValue: "{}");

            migrationBuilder.AddColumn<int>(
                name: "CooldownStretches",
                table: "Profiles",
                type: "int",
                nullable: false,
                defaultValue: 3);

            migrationBuilder.AddColumn<string>(
                name: "RestMode",
                table: "Profiles",
                type: "nvarchar(16)",
                maxLength: 16,
                nullable: false,
                defaultValue: "normal");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "BarWeightsJson",
                table: "Profiles");

            migrationBuilder.DropColumn(
                name: "CooldownStretches",
                table: "Profiles");

            migrationBuilder.DropColumn(
                name: "RestMode",
                table: "Profiles");
        }
    }
}
